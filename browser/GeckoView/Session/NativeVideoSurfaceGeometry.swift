import Foundation
import CoreGraphics

// Both DOM descriptors and native layers are measured in the source tab's
// viewport, even when that tab is retained behind another tab for PiP.
enum NativeVideoSurfaceGeometry {
    static func viewportRect(_ cssRect: CGRect?, viewport: CGSize, bounds: CGRect) -> CGRect? {
        guard let cssRect, valid(cssRect), valid(bounds),
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let rect = CGRect(
            x: bounds.minX + cssRect.minX * bounds.width / viewport.width,
            y: bounds.minY + cssRect.minY * bounds.height / viewport.height,
            width: cssRect.width * bounds.width / viewport.width,
            height: cssRect.height * bounds.height / viewport.height)
        return valid(rect) ? rect : nil
    }

    static func matches(surface: CGRect, visibleVideo: CGRect, bounds: CGRect) -> Bool {
        guard valid(surface), valid(visibleVideo), valid(bounds) else { return false }
        let visibleSurface = surface.intersection(bounds)
        let expected = visibleVideo.intersection(bounds)
        guard valid(visibleSurface), valid(expected) else { return false }
        // Rounding at CSS/device-pixel boundaries is harmless. A neighbouring
        // video must not match just because a few edge pixels overlap.
        let overlap = visibleSurface.intersection(expected.insetBy(dx: -2, dy: -2))
        guard valid(overlap) else { return false }
        let surfaceCoverage = area(overlap) / area(visibleSurface)
        let elementCoverage = area(overlap) / area(expected)
        return surfaceCoverage >= 0.90 && elementCoverage >= 0.25
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
        rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
