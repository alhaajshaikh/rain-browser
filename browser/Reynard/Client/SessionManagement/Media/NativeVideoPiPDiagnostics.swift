// Keep troubleshooting data limited to renderer state and numeric system
// failures. Page addresses, media addresses, and NSError userInfo stay out.

import Foundation

final class NativeVideoPiPDiagnostics {
    enum Stage: String, Codable {
        case requestBegan, videoSelected, waitingForLayer, fullscreenRequested
        case layerAssigned, controllerCreated, controllerReused, waitingForReadiness
        case startRequested, willStart, didStart, willStop, didStop
        case failedToStart, retryScheduled, readinessTimedOut, startTimedOut
        case cancelled, sourceChanged, cleanupBegan, cleanupFinished
    }

    enum SourceKind: String, Codable {
        case direct, browserManaged
    }

    enum Phase: String, Codable {
        case ready, preparing, starting, active, stopping
    }

    struct Snapshot: Codable {
        let sourceKind: SourceKind?
        let width: Double?
        let height: Double?
        let duration: Double?
        let paused: Bool?
        let visibleVideoCount: Int?
        let rendererStatus: Int?
        let frameReady: Bool?
        let possible: Bool?
        let phase: Phase?

        init(sourceKind: SourceKind? = nil, width: Double? = nil, height: Double? = nil,
             duration: Double? = nil, paused: Bool? = nil, visibleVideoCount: Int? = nil,
             rendererStatus: Int? = nil, frameReady: Bool? = nil, possible: Bool? = nil,
             phase: Phase? = nil) {
            self.sourceKind = sourceKind
            self.width = Self.nonnegativeFinite(width)
            self.height = Self.nonnegativeFinite(height)
            self.duration = Self.nonnegativeFinite(duration)
            self.paused = paused
            self.visibleVideoCount = visibleVideoCount.flatMap { $0 >= 0 ? $0 : nil }
            self.rendererStatus = rendererStatus
            self.frameReady = frameReady
            self.possible = possible
            self.phase = phase
        }

        private static func nonnegativeFinite(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
    }

    private struct SystemFailure: Codable {
        let domain: String
        let code: Int
    }

    private struct Event: Codable {
        let elapsed: TimeInterval
        let stage: Stage
        let snapshot: Snapshot
        let errors: [SystemFailure]
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let build: String
        let events: [Event]
    }

    private var origin: TimeInterval
    private var events: [Event] = []

    init(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        origin = uptime.isFinite ? uptime : 0
    }

    func reset(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        origin = uptime.isFinite ? uptime : 0
        events.removeAll(keepingCapacity: true)
    }

    func record(_ stage: Stage, snapshot: Snapshot = .init(), error: Error? = nil,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let elapsed = uptime.isFinite ? max(0, uptime - origin) : 0
        events.append(Event(elapsed: elapsed.isFinite ? elapsed : 0, stage: stage,
                            snapshot: snapshot, errors: Self.failures(error)))
        if events.count > 16 { events.removeFirst(events.count - 16) }
    }

    func report(build: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(build: build, events: events)
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else {
            return "{\"events\":[],\"schemaVersion\":1}"
        }
        return text
    }

    private static func failures(_ error: Error?) -> [SystemFailure] {
        guard let error else { return [] }
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        var result: [SystemFailure] = []
        while let failure = current, result.count < 4 {
            guard seen.insert(ObjectIdentifier(failure)).inserted else { break }
            // A domain is an identifier, not a message. Reject unexpected
            // URL/message-shaped domains rather than copying arbitrary text.
            let domain = failure.domain
            let validDomain = !domain.isEmpty && domain.utf8.count <= 128 &&
                domain.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
                }
            result.append(SystemFailure(domain: validDomain ? domain : "UnrecognizedErrorDomain", code: failure.code))
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}
