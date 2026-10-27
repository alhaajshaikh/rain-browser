// Compile with GeckoView/Session/NativeVideoSurfaceGeometry.swift.
import Foundation
import CoreGraphics

@main
struct NativeVideoSurfaceGeometryChecks {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 700)
        let viewport = CGSize(width: 780, height: 1400)
        let cssVideo = CGRect(x: 20, y: 200, width: 740, height: 420)
        let expected = CGRect(x: 10, y: 100, width: 370, height: 210)
        require(NativeVideoSurfaceGeometry.viewportRect(cssVideo, viewport: viewport, bounds: bounds) == expected,
                "CSS visual-viewport geometry scales into native view points")
        let shifted = CGRect(x: 4, y: 12, width: 390, height: 700)
        require(NativeVideoSurfaceGeometry.viewportRect(cssVideo, viewport: viewport, bounds: shifted) ==
                CGRect(x: 14, y: 112, width: 370, height: 210), "nonzero native bounds origin is respected")
        require(NativeVideoSurfaceGeometry.matches(surface: expected, visibleVideo: expected, bounds: bounds),
                "selected inline video matches its compositor surface")
        let neighbour = expected.offsetBy(dx: 0, dy: 230)
        require(!NativeVideoSurfaceGeometry.matches(surface: neighbour, visibleVideo: expected, bounds: bounds),
                "adjacent equal-sized ad does not match selected video")
        require(!NativeVideoSurfaceGeometry.matches(surface: expected.offsetBy(dx: 350, dy: 0),
                visibleVideo: expected, bounds: bounds), "small edge overlap does not match a neighbour")
        let letterboxed = expected.insetBy(dx: 0, dy: 45)
        require(NativeVideoSurfaceGeometry.matches(surface: letterboxed, visibleVideo: expected, bounds: bounds),
                "aspect-fit video matches inside the DOM element letterbox")
        require(!NativeVideoSurfaceGeometry.matches(surface: expected.insetBy(dx: 150, dy: 90),
                visibleVideo: expected, bounds: bounds), "tiny nested surface does not claim a large player")
        let clipped = CGRect(x: 0, y: -90, width: 390, height: 200)
        require(NativeVideoSurfaceGeometry.matches(surface: clipped,
                visibleVideo: CGRect(x: 0, y: 0, width: 390, height: 110), bounds: bounds),
                "partially scrolled video matches clipped viewport intersection")
        require(NativeVideoSurfaceGeometry.matches(surface: expected.offsetBy(dx: 1, dy: -1),
                visibleVideo: expected, bounds: bounds), "one-point compositing rounding is tolerated")
        require(NativeVideoSurfaceGeometry.viewportRect(cssVideo, viewport: .zero, bounds: bounds) == nil,
                "zero viewport cannot invent a native location")
        require(NativeVideoSurfaceGeometry.viewportRect(nil, viewport: viewport, bounds: bounds) == nil,
                "missing descriptor geometry stays unavailable")
        require(NativeVideoSurfaceGeometry.viewportRect(.null, viewport: viewport, bounds: bounds) == nil,
                "null video rectangle is rejected")
        require(NativeVideoSurfaceGeometry.viewportRect(cssVideo,
                viewport: CGSize(width: CGFloat.infinity, height: 700), bounds: bounds) == nil,
                "nonfinite viewport is rejected")
        require(!NativeVideoSurfaceGeometry.matches(surface: .null, visibleVideo: expected, bounds: bounds),
                "null surface never matches")
        require(!NativeVideoSurfaceGeometry.matches(surface: .infinite, visibleVideo: expected, bounds: bounds),
                "infinite surface never matches")
        require(!NativeVideoSurfaceGeometry.matches(surface: expected, visibleVideo: .zero, bounds: bounds),
                "zero-area player never matches")
        print("Native video surface geometry: 16 checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
