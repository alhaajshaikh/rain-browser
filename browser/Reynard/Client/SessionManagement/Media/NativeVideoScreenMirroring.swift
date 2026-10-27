import UIKit

// The public route picker routes media; it does not start whole-screen
// mirroring. Leave system mirroring selection to Control Center.
enum NativeVideoScreenMirroring {
    static func makeGuide() -> UIAlertController {
        let alert = UIAlertController(
            title: NSLocalizedString("Screen Mirroring", comment: ""),
            message: NSLocalizedString("Swipe down from the top-right corner to open Control Center, tap Screen Mirroring (two overlapping rectangles), then choose your TV. On an iPhone with a Home button, swipe up from the bottom instead.\n\nConnect your phone and TV to the same Wi-Fi network and keep Rain open while mirroring.", comment: "Instructions for using system screen mirroring"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Done", comment: ""), style: .default))
        return alert
    }
}
