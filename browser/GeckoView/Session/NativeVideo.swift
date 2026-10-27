// Native video requests stay inside Gecko's privileged content actors. A target
// includes the document identity, so a late command cannot control a new page.

import Foundation
import CoreGraphics

public struct NativeVideo {
    public struct SeekableRange: Equatable {
        public let start: Double
        public let end: Double
    }

    public let token: String
    public let browsingContextID: String
    public let innerWindowID: String
    public let url: URL?
    public let currentTime: Double
    public let duration: Double?
    public let paused: Bool
    public let ended: Bool
    public let readyState: Int
    public let playbackRate: Double
    public let muted: Bool
    public let volume: Double
    public let title: String
    public let width: Double
    public let height: Double
    public let seekableStart: Double?
    public let seekableEnd: Double?
    public let seekableRanges: [SeekableRange]
    public let isLive: Bool
    public let sampledAtUptime: TimeInterval
    public let hasProtectedContent: Bool
    public let userAgent: String
    public let isFullscreen: Bool
    public let visibleArea: Double
    public let visibleRect: CGRect?
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let totalVisibleVideoCount: Int

    init?(_ payload: Any?) {
        guard let data = payload as? [String: Any],
              let token = data["token"] as? String,
              let context = data["browsingContextID"] as? String,
              let window = data["innerWindowID"] as? String,
              !token.isEmpty, !context.isEmpty, !window.isEmpty else { return nil }
        self.token = token
        browsingContextID = context
        innerWindowID = window
        let candidate = (data["url"] as? String).flatMap(URL.init(string:))
        url = candidate.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        currentTime = Self.finite(data["currentTime"]) ?? 0
        duration = Self.finite(data["duration"])
        paused = data["paused"] as? Bool ?? true
        ended = data["ended"] as? Bool ?? false
        readyState = min(4, max(0, data["readyState"] as? Int ?? 0))
        playbackRate = Self.finite(data["playbackRate"]) ?? 1
        muted = data["muted"] as? Bool ?? false
        volume = min(1, max(0, Self.finite(data["volume"]) ?? 1))
        title = data["title"] as? String ?? ""
        width = Self.finite(data["width"]) ?? 0
        height = Self.finite(data["height"]) ?? 0
        seekableStart = Self.finite(data["seekableStart"])
        seekableEnd = Self.finite(data["seekableEnd"])
        let ranges = (data["seekableRanges"] as? [[String: Any]] ?? []).compactMap { range -> SeekableRange? in
            guard let start = Self.finite(range["start"]),
                  let end = Self.finite(range["end"]), start >= 0, end > start else { return nil }
            return SeekableRange(start: start, end: end)
        }.sorted { $0.start < $1.start }
        if ranges.isEmpty, let start = seekableStart, let end = seekableEnd, start >= 0, end > start {
            seekableRanges = [SeekableRange(start: start, end: end)]
        } else {
            seekableRanges = ranges
        }
        isLive = data["isLive"] as? Bool ?? false
        sampledAtUptime = ProcessInfo.processInfo.systemUptime
        hasProtectedContent = data["hasProtectedContent"] as? Bool ?? false
        userAgent = data["userAgent"] as? String ?? ""
        isFullscreen = data["isFullscreen"] as? Bool ?? false
        visibleArea = Self.finite(data["visibleArea"]) ?? 0
        viewportWidth = Self.finite(data["viewportWidth"]) ?? 0
        viewportHeight = Self.finite(data["viewportHeight"]) ?? 0
        if let rect = data["visibleRect"] as? [String: Any],
           let x = Self.finite(rect["x"]), let y = Self.finite(rect["y"]),
           let width = Self.finite(rect["width"]), let height = Self.finite(rect["height"]),
           width > 0, height > 0, viewportWidth > 0, viewportHeight > 0 {
            visibleRect = CGRect(x: x, y: y, width: width, height: height)
        } else {
            visibleRect = nil
        }
        totalVisibleVideoCount = data["totalVisibleVideoCount"] as? Int ?? 0
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let value = value as? Double, value.isFinite else { return nil }
        return value
    }

    var target: [String: Any?] {
        ["token": token, "browsingContextID": browsingContextID, "innerWindowID": innerWindowID]
    }
}

public enum NativeMediaCommand {
    case play, pause, stop, nextTrack, previousTrack
    case seekForward(Double), seekBackward(Double), seekTo(Double), mute(Bool)
}

public protocol NativeMediaPlayback: AnyObject {
    func handleNativeMediaCommand(_ command: NativeMediaCommand)
}

private struct NativeVideoRequestError: LocalizedError {
    let message: String

    init(_ response: Any?) {
        if let value = response as? String, !value.isEmpty {
            message = value
        } else if let details = response as? [String: Any],
                  let value = details["message"] as? String, !value.isEmpty {
            message = value
        } else {
            message = NSLocalizedString("The browser could not complete the video request. Please try again.", comment: "")
        }
    }

    var errorDescription: String? { message }
}

private func decodeNativeVideoResponse(_ payload: Any?) throws -> NativeVideo? {
    // A null response means there is no video. An unexpected non-null payload
    // indicates a bridge failure and must not be presented as user error.
    guard let payload, !(payload is NSNull) else { return nil }
    guard let video = NativeVideo(payload) else {
        throw NativeVideoRequestError(NSLocalizedString(
            "The browser returned an invalid video response. Please reload the page and try again.", comment: ""))
    }
    return video
}

private final class NativeVideoCallback: NSObject, EventCallback {
    private var continuation: CheckedContinuation<Any?, Error>?
    private var timeout: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Any?, Error>) {
        self.continuation = continuation
        super.init()
        let work = DispatchWorkItem { [weak self] in
            self?.sendError("The video request timed out")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func sendSuccess(_ response: Any?) {
        timeout?.cancel()
        timeout = nil
        continuation?.resume(returning: response)
        continuation = nil
    }

    func sendError(_ response: Any?) {
        timeout?.cancel()
        timeout = nil
        continuation?.resume(throwing: NativeVideoRequestError(response))
        continuation = nil
    }

    deinit {
        timeout?.cancel()
        continuation?.resume(throwing: NativeVideoRequestError(NSLocalizedString("The video request was cancelled.", comment: "")))
    }
}

public extension GeckoSession {
    static let didCloseNotification = Notification.Name("GeckoSessionDidClose")

    func nativeVideo() async throws -> NativeVideo? {
        guard isOpen() else { return nil }
        return try decodeNativeVideoResponse(await queryNativeVideo(type: "GeckoView:NativeVideo:Get"))
    }

    @discardableResult
    func commandNativeVideo(_ video: NativeVideo, command: String,
                            values: [String: Any?] = [:]) async throws -> NativeVideo? {
        guard isOpen() else { return nil }
        var message = video.target
        message["command"] = command
        message.merge(values) { _, new in new }
        let response = try await queryNativeVideo(type: "GeckoView:NativeVideo:Command", message: message)
        // The release command acknowledges retirement without a descriptor.
        if ["release", "follow"].contains(command), response as? Bool == true { return nil }
        return try decodeNativeVideoResponse(response)
    }

    private func queryNativeVideo(type: String, message: [String: Any?]? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            dispatcher.dispatch(type: type, message: message, callback: NativeVideoCallback(continuation))
        }
    }
}
