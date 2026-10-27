import Foundation

// Keep the custom playback controls preference adjacent to the AVKit feature,
// while using the same profile-scoped keys as the browser's settings.
enum NativeVideoPreferences {
    static let didChangeNotification = Notification.Name("NativeVideoPreferencesDidChange")

    private static var buttonKey: String {
        BrowserPreferences.shared.key("NativeVideoSettings", "showsNativePlayerButton")
    }

    static var showsNativePlayerButton: Bool {
        get { UserDefaults.standard.object(forKey: buttonKey) as? Bool ?? true }
        set {
            guard showsNativePlayerButton != newValue else { return }
            UserDefaults.standard.set(newValue, forKey: buttonKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
