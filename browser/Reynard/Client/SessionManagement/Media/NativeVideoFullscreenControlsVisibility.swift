import Foundation

// One deadline governs the entire overlay, including a preparation spinner.
// Keeping this independent of UIKit makes timer and accessibility changes
// predictable even when a cancelled timer was already queued for delivery.
struct NativeVideoFullscreenControlsVisibility {
    static let visibleDuration: TimeInterval = 3

    private(set) var isAttached = false
    private(set) var voiceOverEnabled = false
    private(set) var hideDeadline: TimeInterval?

    var isVisible: Bool { isAttached && (voiceOverEnabled || hideDeadline != nil) }

    mutating func attach(at now: TimeInterval, voiceOver: Bool) {
        isAttached = true
        voiceOverEnabled = voiceOver
        reveal(at: now)
    }

    mutating func detach() {
        isAttached = false
        hideDeadline = nil
    }

    mutating func reveal(at now: TimeInterval) {
        guard isAttached else { return }
        hideDeadline = voiceOverEnabled ? nil : now + Self.visibleDuration
    }

    mutating func setVoiceOver(_ enabled: Bool, at now: TimeInterval) {
        voiceOverEnabled = enabled
        reveal(at: now)
    }

    mutating func hideAfterAction() {
        guard !voiceOverEnabled else { return }
        hideDeadline = nil
    }

    mutating func expire(at now: TimeInterval) {
        guard let hideDeadline, now >= hideDeadline else { return }
        self.hideDeadline = nil
    }
}
