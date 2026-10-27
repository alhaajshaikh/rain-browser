// Compile alongside the production NativeVideo.swift to exercise the actual
// Swift response boundary without UIKit, Gecko, or an installed iPhone app.
import Foundation
import CoreGraphics

protocol EventCallback: AnyObject {
    func sendSuccess(_ response: Any?)
    func sendError(_ response: Any?)
}

struct ResponseDispatcher {
    var response: Any?
    var fails = false

    func dispatch(type: String, message: [String: Any?]? = nil, callback: EventCallback?) {
        if fails { callback?.sendError(response) }
        else { callback?.sendSuccess(response) }
    }
}

public final class GeckoSession {
    var dispatcher = ResponseDispatcher()
    func isOpen() -> Bool { true }
}

@main
struct NativeVideoResponseChecks {
    static func expectError(_ fragment: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            fatalError("Expected an error containing \(fragment)")
        } catch {
            precondition(error.localizedDescription.contains(fragment), error.localizedDescription)
        }
    }

    static func main() async throws {
        let session = GeckoSession()
        let empty = try await session.nativeVideo()
        precondition(empty == nil)
        session.dispatcher.response = NSNull()
        let explicitNull = try await session.nativeVideo()
        precondition(explicitNull == nil)

        // The real C++ bridge returns a toll-free bridged CFDictionary, with
        // CFString, CFNumber, CFBoolean, and CFNull property values.
        session.dispatcher.response = [
            "token": "video-token", "browsingContextID": "42", "innerWindowID": "99",
            "url": NSNull(), "width": NSNumber(value: 1920), "height": NSNumber(value: 1080),
            "currentTime": NSNumber(value: 12.5), "paused": NSNumber(value: false),
            "totalVisibleVideoCount": NSNumber(value: 1), "ended": NSNumber(value: true),
            "readyState": NSNumber(value: 2),
            "viewportWidth": NSNumber(value: 430), "viewportHeight": NSNumber(value: 800),
            "visibleRect": ["x": 10.0, "y": 200.0, "width": 400.0, "height": 225.0],
        ] as NSDictionary
        guard let selected = try await session.nativeVideo() else { fatalError("Missing valid descriptor") }
        precondition(selected.token == "video-token" && selected.url == nil)
        precondition(selected.width == 1920 && selected.currentTime == 12.5 && !selected.paused)
        precondition(selected.totalVisibleVideoCount == 1)
        precondition(selected.readyState == 2)
        precondition(selected.ended && selected.viewportWidth == 430 && selected.viewportHeight == 800)
        precondition(selected.visibleRect == CGRect(x: 10, y: 200, width: 400, height: 225))

        session.dispatcher.response = ["token": "video-token"] as NSDictionary
        await expectError("invalid video response") { _ = try await session.nativeVideo() }
        session.dispatcher.response = "unexpected payload"
        await expectError("invalid video response") { _ = try await session.nativeVideo() }

        session.dispatcher.response = "Cannot select video: owner window unavailable"
        session.dispatcher.fails = true
        await expectError("owner window unavailable") { _ = try await session.nativeVideo() }
        session.dispatcher.response = ["message": "The selected frame is unavailable"] as NSDictionary
        await expectError("selected frame is unavailable") { _ = try await session.nativeVideo() }
        session.dispatcher.response = NSNull()
        await expectError("could not complete the video request") { _ = try await session.nativeVideo() }

        session.dispatcher.fails = false
        session.dispatcher.response = true
        let released = try await session.commandNativeVideo(selected, command: "release")
        precondition(released == nil)
        let disarmed = try await session.commandNativeVideo(selected, command: "follow", values: ["enabled": false])
        precondition(disarmed == nil)
        await expectError("invalid video response") {
            _ = try await session.commandNativeVideo(selected, command: "status")
        }
        print("NativeVideo response boundary: 14 checks passed")
    }
}
