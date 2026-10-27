import Foundation

private final class CyclicSystemError: NSError, @unchecked Sendable {
    init() { super.init(domain: "CycleErrorDomain", code: 42, userInfo: nil) }
    required init?(coder: NSCoder) { fatalError("Not used by this check") }
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

@main
struct NativeVideoPiPDiagnosticsChecks {
    static func decode(_ diagnostics: NativeVideoPiPDiagnostics, build: String = "2026102606") -> [String: Any] {
        let data = Data(diagnostics.report(build: build).utf8)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func main() {
        let diagnostics = NativeVideoPiPDiagnostics(uptime: 100)
        for index in 0..<30 {
            diagnostics.record(.waitingForReadiness,
                               snapshot: .init(rendererStatus: index, frameReady: index > 20),
                               uptime: 100 + Double(index))
        }
        let bounded = decode(diagnostics)
        let events = bounded["events"] as! [[String: Any]]
        precondition(events.count == 16, "Long readiness waits must not grow the report indefinitely")
        precondition(events.first?["elapsed"] as? Double == 14, "History retains the newest events in their original order")
        precondition(events.last?["elapsed"] as? Double == 29, "Times are relative to the request, without wall-clock timestamps")
        precondition(bounded["build"] as? String == "2026102606")

        let mediaURL = "https://example.test/private-video?token=secret"
        let leaf = NSError(domain: NSOSStatusErrorDomain, code: -50, userInfo: [
            NSLocalizedDescriptionKey: "Cannot load \(mediaURL)", NSURLErrorKey: URL(string: mediaURL)!
        ])
        let middle = NSError(domain: "CoreMediaErrorDomain", code: -12780, userInfo: [NSUnderlyingErrorKey: leaf])
        let outer = NSError(domain: "AVKitErrorDomain", code: -1001, userInfo: [
            NSUnderlyingErrorKey: middle, NSLocalizedFailureReasonErrorKey: mediaURL,
            "cookies": "private-cookie", "title": "private-title", "token": "private-token"
        ])
        diagnostics.reset(uptime: 200)
        diagnostics.record(.failedToStart,
                           snapshot: .init(sourceKind: .browserManaged, width: 1920, height: 1080,
                                           duration: 120, paused: false, visibleVideoCount: 1,
                                           rendererStatus: 1, frameReady: true, possible: true, phase: .starting),
                           error: outer, uptime: 202.5)
        let failureReport = decode(diagnostics)
        let failureEvents = failureReport["events"] as! [[String: Any]]
        precondition(failureEvents.count == 1, "A new request resets the previous request's history")
        precondition(failureEvents[0]["elapsed"] as? Double == 2.5)
        let failures = failureEvents[0]["errors"] as! [[String: Any]]
        precondition(failures.compactMap { $0["code"] as? Int } == [-1001, -12780, -50],
                     "Keep the underlying numeric failure that a generic AVKit error hides")
        precondition(failures.last?["domain"] as? String == NSOSStatusErrorDomain)
        let encoded = diagnostics.report(build: "2026102606")
        for privateValue in ["https", "example.test", "secret", "private-cookie", "private-title", "private-token", "localizedDescription", "userInfo"] {
            precondition(!encoded.contains(privateValue), "Do not serialize URLs, credentials, titles, tokens, or NSError userInfo")
        }

        var chain: NSError = leaf
        for index in 0..<10 {
            chain = NSError(domain: "AVFoundationErrorDomain", code: index, userInfo: [NSUnderlyingErrorKey: chain])
        }
        diagnostics.reset(uptime: 0)
        diagnostics.record(.failedToStart, error: chain, uptime: 1)
        let chainEvents = decode(diagnostics)["events"] as! [[String: Any]]
        let chainErrors = chainEvents[0]["errors"] as! [[String: Any]]
        precondition(chainErrors.count == 4, "An unexpected underlying-error chain remains bounded")
        precondition(chainErrors.compactMap { $0["code"] as? Int } == [9, 8, 7, 6])

        diagnostics.reset(uptime: 0)
        diagnostics.record(.failedToStart, error: CyclicSystemError(), uptime: 1)
        let cyclicEvents = decode(diagnostics)["events"] as! [[String: Any]]
        let cyclicErrors = cyclicEvents[0]["errors"] as! [[String: Any]]
        precondition(cyclicErrors.count == 1 && cyclicErrors[0]["code"] as? Int == 42,
                     "Repeated NSError identities stop traversal before duplicating or looping")

        diagnostics.reset(uptime: .infinity)
        diagnostics.record(.layerAssigned,
                           snapshot: .init(width: .nan, height: -.infinity, duration: .infinity,
                                           visibleVideoCount: -1),
                           error: NSError(domain: mediaURL, code: 7), uptime: .nan)
        let invalidEvents = decode(diagnostics)["events"] as! [[String: Any]]
        let invalidSnapshot = invalidEvents[0]["snapshot"] as! [String: Any]
        precondition(invalidSnapshot.isEmpty, "Unavailable or nonfinite metadata must not break JSON encoding")
        precondition(invalidEvents[0]["elapsed"] as? Double == 0)
        let invalidErrors = invalidEvents[0]["errors"] as! [[String: Any]]
        precondition(invalidErrors[0]["domain"] as? String == "UnrecognizedErrorDomain",
                     "An unexpected message-shaped error domain cannot smuggle a URL into the report")
        precondition(!diagnostics.report(build: "2026102606").contains("example.test"))

        print("NativeVideo PiP diagnostics: bounded history, relative time, underlying error codes, cycles, and private-data exclusion checks passed")
    }
}
