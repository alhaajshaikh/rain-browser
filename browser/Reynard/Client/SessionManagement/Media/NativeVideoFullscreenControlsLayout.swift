import Foundation
import CoreGraphics

// Keep the visible controls in the video's letterbox bars while preserving
// 44-point touch targets. This geometry is independent of UIKit for testing.
struct NativeVideoFullscreenControlsLayout {
    let actionsFrame: CGRect
    let actionsVisualFrame: CGRect
    let revealFrame: CGRect
    let revealVisualFrame: CGRect
    let keepsActionsVisible: Bool
    let revealOverlapsVideo: Bool

    static let touchWidth: CGFloat = 44
    // SF Symbols such as play.rectangle are wider than their point size.
    // Forty points leaves padding around them instead of a pinched capsule.
    static let visualWidth: CGFloat = 40
    static let actionsHeight: CGFloat = 96
    static let singleActionHeight: CGFloat = 48

    static func make(bounds: CGRect, safeFrame: CGRect, videoSize: CGSize?,
                     videoFrame: CGRect? = nil, showsNativePlayerButton: Bool = true) -> Self {
        let intersection = bounds.intersection(safeFrame)
        let safe = intersection.isNull || intersection.isEmpty
            ? CGRect(origin: bounds.origin, size: .zero) : intersection
        let requestedHeight = showsNativePlayerButton ? Self.actionsHeight : Self.singleActionHeight
        guard safe.width >= Self.touchWidth, safe.height >= requestedHeight else {
            return Self(actionsFrame: .zero, actionsVisualFrame: .zero,
                        revealFrame: .zero, revealVisualFrame: .zero,
                        keepsActionsVisible: false, revealOverlapsVideo: false)
        }
        let touchWidth = min(Self.touchWidth, max(0, safe.width))
        let touchHeight = min(Self.touchWidth, max(0, safe.height))
        let actionsHeight = min(requestedHeight, max(0, safe.height))
        let picture = valid(videoFrame, inside: bounds) ?? aspectFit(videoSize, in: bounds)
        var margins: [CGRect] = []
        if let picture {
            // Prefer a side bar. In portrait, a top or bottom bar may provide
            // more room; the icons still form an upright vertical column.
            margins = [
                CGRect(x: max(safe.minX, picture.maxX), y: safe.minY,
                       width: max(0, safe.maxX - max(safe.minX, picture.maxX)), height: safe.height),
                CGRect(x: safe.minX, y: safe.minY,
                       width: max(0, min(safe.maxX, picture.minX) - safe.minX), height: safe.height),
                CGRect(x: safe.minX, y: max(safe.minY, picture.maxY), width: safe.width,
                       height: max(0, safe.maxY - max(safe.minY, picture.maxY))),
                CGRect(x: safe.minX, y: safe.minY, width: safe.width,
                       height: max(0, min(safe.maxY, picture.minY) - safe.minY))
            ]
        }
        if let margin = margins.first(where: { $0.width >= Self.visualWidth && $0.height >= requestedHeight }) {
            let visual = CGRect(x: margin.midX - Self.visualWidth / 2, y: margin.midY - actionsHeight / 2,
                                width: Self.visualWidth, height: actionsHeight)
            let hit = CGRect(x: clamp(visual.midX - touchWidth / 2, safe.minX, safe.maxX - touchWidth),
                             y: visual.minY, width: touchWidth, height: actionsHeight)
            return Self(actionsFrame: hit, actionsVisualFrame: visual,
                        revealFrame: .zero, revealVisualFrame: .zero,
                        keepsActionsVisible: true, revealOverlapsVideo: false)
        }

        // No usable bar: keep a fully padded column near the trailing edge.
        // The view hides it using the same timer as controls in a letterbox.
        let reveal = CGRect(x: safe.maxX - touchWidth, y: safe.midY - touchHeight / 2,
                            width: touchWidth, height: touchHeight)
        let visualWidth = min(Self.visualWidth, touchWidth)
        let visible = CGRect(x: reveal.maxX - visualWidth, y: reveal.minY,
                             width: visualWidth, height: touchHeight)
        let visiblePicture = valid(picture, inside: safe)
        let actions = CGRect(x: reveal.minX,
                             y: clamp((visiblePicture?.midY ?? safe.midY) - actionsHeight / 2,
                                      safe.minY, safe.maxY - actionsHeight),
                             width: touchWidth, height: actionsHeight)
        let actionsVisual = CGRect(x: actions.midX - visualWidth / 2, y: actions.minY,
                                   width: visualWidth, height: actions.height)
        return Self(actionsFrame: actions, actionsVisualFrame: actionsVisual,
                    revealFrame: reveal, revealVisualFrame: visible,
                    keepsActionsVisible: false,
                    revealOverlapsVideo: picture.map { $0.intersects(visible) } ?? true)
    }

    // Inline controls belong to the visible video rectangle, rather than the
    // page's edge or its letterbox margins. Only PiP is shown in this mode.
    static func inline(bounds: CGRect, safeFrame: CGRect, videoFrame: CGRect?) -> Self {
        let visible = valid(videoFrame, inside: bounds)?.intersection(safeFrame)
        guard let visible, !visible.isNull, visible.width >= touchWidth,
              visible.height >= touchWidth else {
            return Self(actionsFrame: .zero, actionsVisualFrame: .zero,
                        revealFrame: .zero, revealVisualFrame: .zero,
                        keepsActionsVisible: false, revealOverlapsVideo: false)
        }
        let inset: CGFloat = 4
        // A portrait phone commonly shows a landscape YouTube video inline.
        // Put its button midway down the trailing edge, clear of top controls.
        let centered = bounds.height >= bounds.width ||
            (videoFrame.map { $0.height > $0.width } ?? false)
        let hit = CGRect(x: max(visible.minX, visible.maxX - touchWidth - inset),
                         y: centered ? visible.midY - touchWidth / 2 :
                            min(visible.maxY - touchWidth, visible.minY + inset),
                         width: touchWidth, height: touchWidth)
        return Self(actionsFrame: hit, actionsVisualFrame: hit,
                    revealFrame: .zero, revealVisualFrame: .zero,
                    keepsActionsVisible: false, revealOverlapsVideo: true)
    }

    private static func valid(_ frame: CGRect?, inside bounds: CGRect) -> CGRect? {
        guard let frame, !frame.isNull, frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 1, frame.height > 1 else { return nil }
        let visible = frame.intersection(bounds)
        return visible.isNull || visible.isEmpty ? nil : visible
    }

    private static func aspectFit(_ size: CGSize?, in bounds: CGRect) -> CGRect? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}
