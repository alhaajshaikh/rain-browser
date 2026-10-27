// Compile this together with NativeVideoFullscreenControlsVisibility.swift.
import Foundation

@main
struct NativeVideoFullscreenControlsVisibilityChecks {
    static func main() {
        var controls = NativeVideoFullscreenControlsVisibility()
        require(!controls.isVisible, "unattached controls are hidden")
        controls.reveal(at: 0)
        require(!controls.isVisible && controls.hideDeadline == nil, "a detached tap cannot schedule a timer")

        controls.attach(at: 10, voiceOver: false)
        require(controls.isVisible && controls.hideDeadline == 13, "fullscreen entry reveals controls for three seconds")
        controls.expire(at: 12.999)
        require(controls.isVisible, "controls remain available for the full interval")
        controls.expire(at: 13)
        require(!controls.isVisible && controls.hideDeadline == nil, "the entire overlay disappears at its deadline")

        controls.reveal(at: 20)
        require(controls.isVisible && controls.hideDeadline == 23, "a video tap reveals hidden controls")
        controls.reveal(at: 22)
        controls.expire(at: 23)
        require(controls.isVisible && controls.hideDeadline == 25, "a queued old timer cannot hide freshly revealed controls")
        controls.expire(at: 25)
        require(!controls.isVisible, "the renewed deadline still expires")

        controls.reveal(at: 30)
        controls.hideAfterAction()
        require(!controls.isVisible && controls.hideDeadline == nil, "starting PiP hides controls immediately")
        controls.expire(at: 33)
        require(!controls.isVisible, "the old action timer cannot reveal controls")

        controls.attach(at: 40, voiceOver: true)
        require(controls.isVisible && controls.hideDeadline == nil, "VoiceOver keeps actions available without a timer")
        controls.expire(at: 100)
        controls.hideAfterAction()
        require(controls.isVisible, "VoiceOver navigation and actions never hide the controls")
        controls.setVoiceOver(false, at: 110)
        require(controls.isVisible && controls.hideDeadline == 113, "disabling VoiceOver starts a fresh full interval")
        controls.expire(at: 113)
        require(!controls.isVisible, "normal hiding resumes after VoiceOver is disabled")
        controls.setVoiceOver(true, at: 120)
        require(controls.isVisible && controls.hideDeadline == nil, "enabling VoiceOver reveals previously hidden actions")

        controls.detach()
        require(!controls.isVisible && controls.hideDeadline == nil, "leaving fullscreen clears timer state")
        controls.setVoiceOver(false, at: 130)
        require(!controls.isVisible && controls.hideDeadline == nil, "accessibility changes cannot reveal a detached overlay")
        controls.attach(at: 140, voiceOver: false)
        controls.expire(at: 133)
        require(controls.isVisible && controls.hideDeadline == 143, "an old fullscreen timer cannot hide a new attachment")
        controls.detach()
        controls.expire(at: 1000)
        require(!controls.isVisible, "a detached overlay stays hidden after late timer delivery")
        print("Native video fullscreen visibility: 19 checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
