// Compile this together with NativeVideoFullscreenControlsLayout.swift.
import Foundation
import CoreGraphics

@main
struct NativeVideoFullscreenControlsLayoutTests {
    private static var checkCount = 0

    static func main() {
        let landscape = CGRect(x: 0, y: 0, width: 932, height: 430)
        let landscapeSafe = CGRect(x: 59, y: 0, width: 814, height: 409)
        let widescreen = CGSize(width: 1920, height: 1080)
        let youtube = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: widescreen)
        let picture = CGRect(x: (932 - 430 * 16 / 9) / 2, y: 0, width: 430 * 16 / 9, height: 430)
        require(!youtube.keepsActionsVisible, "a narrow letterbox does not squeeze the icons' pill")
        require(youtube.actionsVisualFrame.intersects(picture), "a padded overlay is used when the letterbox is too narrow")
        require(landscapeSafe.contains(youtube.actionsFrame), "44-point hit area stays inside safe area")
        require(youtube.actionsFrame.width == 44 && youtube.actionsVisualFrame.width == 40,
                "padded visuals preserve a full hit target")
        require(youtube.actionsFrame.height == 96, "two upright buttons form a vertical column")

        let ultrawide = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: CGSize(width: 2560, height: 1080))
        require(!ultrawide.keepsActionsVisible, "ultrawide content collapses controls when bars are too small")
        require(landscapeSafe.contains(ultrawide.revealFrame), "collapsed hit area respects safe area")
        require(ultrawide.actionsVisualFrame.width == 40, "a vertical pill never narrows below its icon padding")
        require(landscapeSafe.contains(ultrawide.actionsFrame), "temporary expanded actions stay on screen")
        let narrowVideo = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: CGSize(width: 4, height: 3))
        let narrowPicture = CGRect(x: (932 - 430 * 4 / 3) / 2, y: 0, width: 430 * 4 / 3, height: 430)
        require(narrowVideo.keepsActionsVisible && !narrowVideo.actionsVisualFrame.intersects(narrowPicture),
                "a sufficiently wide letterbox keeps the fully padded pill outside the picture")
        require(narrowVideo.actionsVisualFrame.width == 40, "letterbox pills keep the same width as overlay pills")

        let portrait = CGRect(x: 0, y: 0, width: 430, height: 932)
        let portraitSafe = CGRect(x: 0, y: 59, width: 430, height: 839)
        let rotated = NativeVideoFullscreenControlsLayout.make(
            bounds: portrait, safeFrame: portraitSafe, videoSize: widescreen)
        let portraitPicture = CGRect(x: 0, y: (932 - 430 * 9 / 16) / 2, width: 430, height: 430 * 9 / 16)
        require(rotated.keepsActionsVisible, "portrait rotation uses the larger letterbox margin")
        require(!rotated.actionsVisualFrame.intersects(portraitPicture), "portrait controls leave the picture clear")
        require(portraitSafe.contains(rotated.actionsFrame), "portrait hit targets remain in safe area")

        let nativeFrame = CGRect(x: 160, y: 0, width: 600, height: 430)
        let actual = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: CGSize(width: 932, height: 430),
            videoFrame: nativeFrame)
        require(actual.keepsActionsVisible && !actual.actionsVisualFrame.intersects(nativeFrame),
                "actual compositor frame takes precedence over an aspect estimate")

        let unknown = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: nil)
        require(!unknown.keepsActionsVisible && unknown.revealOverlapsVideo,
                "unknown geometry defaults to a faded compact handle")
        let invalid = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe,
            videoSize: CGSize(width: CGFloat.infinity, height: 1080), videoFrame: .null)
        require(!invalid.keepsActionsVisible, "invalid geometry never invents a letterbox margin")
        let empty = NativeVideoFullscreenControlsLayout.make(bounds: .zero, safeFrame: .zero, videoSize: nil)
        require(empty.revealFrame.minX.isFinite && empty.actionsFrame.minY.isFinite,
                "initial empty bounds produce finite frames")
        let inlineVideo = CGRect(x: 15, y: 200, width: 400, height: 225)
        let inline = NativeVideoFullscreenControlsLayout.inline(
            bounds: portrait, safeFrame: portraitSafe, videoFrame: inlineVideo)
        require(inlineVideo.contains(inline.actionsFrame), "inline PiP stays inside its embedded video")
        require(inline.actionsFrame.size == CGSize(width: 44, height: 44), "inline PiP keeps a full touch target")
        require(inline.actionsFrame.midY == inlineVideo.midY, "a portrait phone puts inline PiP at middle-right")
        require(inline.actionsFrame.maxX == inlineVideo.maxX - 4, "portrait inline PiP retains a trailing inset")
        let landscapeInlineFrame = CGRect(x: 100, y: 80, width: 500, height: 280)
        let landscapeInline = NativeVideoFullscreenControlsLayout.inline(
            bounds: landscape, safeFrame: landscapeSafe, videoFrame: landscapeInlineFrame)
        require(landscapeInline.actionsFrame.minY == 84, "landscape inline players retain top trailing placement")
        let tallInlineFrame = CGRect(x: 330, y: 30, width: 180, height: 360)
        let tallInline = NativeVideoFullscreenControlsLayout.inline(
            bounds: landscape, safeFrame: landscapeSafe, videoFrame: tallInlineFrame)
        require(tallInline.actionsFrame.midY == tallInlineFrame.midY, "a tall video also uses middle-right on a landscape host")
        let partlyClipped = NativeVideoFullscreenControlsLayout.inline(
            bounds: portrait, safeFrame: portraitSafe,
            videoFrame: CGRect(x: -20, y: 10, width: 300, height: 200))
        require(portraitSafe.contains(partlyClipped.actionsFrame), "clipped inline controls stay in the safe area")
        let tiny = NativeVideoFullscreenControlsLayout.inline(
            bounds: portrait, safeFrame: portraitSafe,
            videoFrame: CGRect(x: 0, y: 100, width: 30, height: 30))
        require(tiny.actionsFrame.isEmpty, "tiny previews do not create buttons outside the video")
        let unavailable = NativeVideoFullscreenControlsLayout.inline(
            bounds: portrait, safeFrame: portraitSafe, videoFrame: nil)
        require(unavailable.actionsFrame.isEmpty, "missing inline geometry produces no floating page button")
        let oneButton = NativeVideoFullscreenControlsLayout.make(
            bounds: portrait, safeFrame: portraitSafe, videoSize: widescreen,
            showsNativePlayerButton: false)
        require(oneButton.actionsFrame.height == 48 && oneButton.actionsVisualFrame.height == 48,
                "hiding native playback compacts the fullscreen pill to one button")
        require(oneButton.actionsFrame.width == 44 && oneButton.actionsVisualFrame.width == 40,
                "a one-button pill retains icon padding and a full hit target")
        let tallFullscreen = NativeVideoFullscreenControlsLayout.make(
            bounds: portrait, safeFrame: portraitSafe, videoSize: CGSize(width: 9, height: 16))
        require(!tallFullscreen.keepsActionsVisible && abs(tallFullscreen.actionsFrame.midY - portrait.midY) < 0.001,
                "a tall fullscreen video centers its fallback pill on the actual picture")
        let brieflyNarrow = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: CGRect(x: 0, y: 0, width: 30, height: 400), videoSize: widescreen)
        require(brieflyNarrow.actionsFrame.isEmpty, "transient narrow safe areas hide controls instead of pinching them")
        let brieflyShort = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: CGRect(x: 0, y: 0, width: 400, height: 50), videoSize: widescreen)
        require(brieflyShort.actionsFrame.isEmpty, "a short safe area cannot spill the second button outside its pill")
        let shortSingle = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: CGRect(x: 0, y: 0, width: 400, height: 50), videoSize: widescreen,
            showsNativePlayerButton: false)
        require(shortSingle.actionsFrame.height == 48, "a short safe area can still fit the single-button pill")
        // Recompute after rotation/preference changes rather than preserving
        // narrower transient geometry from a prior layout.
        let restored = NativeVideoFullscreenControlsLayout.make(
            bounds: landscape, safeFrame: landscapeSafe, videoSize: widescreen)
        require(restored.actionsFrame == youtube.actionsFrame && restored.actionsVisualFrame == youtube.actionsVisualFrame,
                "valid geometry recovers after narrow and one-button layouts")
        for (name, size) in [("portrait", CGSize(width: 9, height: 16)),
                             ("landscape", widescreen), ("square", CGSize(width: 1, height: 1)),
                             ("ultrawide", CGSize(width: 32, height: 9))] {
            for (host, safe) in [(landscape, landscapeSafe), (portrait, portraitSafe)] {
                let layout = NativeVideoFullscreenControlsLayout.make(bounds: host, safeFrame: safe, videoSize: size)
                require(layout.actionsVisualFrame.width == 40 && layout.actionsFrame.width == 44,
                        "\(name) video preserves pill and touch widths in either host orientation")
                require(safe.contains(layout.actionsFrame), "\(name) video keeps actions within the safe area")
            }
        }
        for (width, fitsBar) in [(CGFloat(733.8), true), (CGFloat(734), true), (CGFloat(734.2), false)] {
            let actualFrame = CGRect(x: (landscape.width - width) / 2, y: 0, width: width, height: landscape.height)
            let layout = NativeVideoFullscreenControlsLayout.make(
                bounds: landscape, safeFrame: landscapeSafe, videoSize: CGSize(width: 9, height: 16),
                videoFrame: actualFrame)
            require(layout.keepsActionsVisible == fitsBar, "actual surface geometry controls the minimum-width threshold")
            require(layout.actionsVisualFrame.width == 40, "crossing a letterbox threshold never squeezes the pill")
        }
        print("Native video controls layout: \(checkCount) checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checkCount += 1
    }
}
