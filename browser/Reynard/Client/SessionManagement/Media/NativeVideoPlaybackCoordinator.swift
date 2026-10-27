// AVKit integration is kept here so upstream browser changes have few hooks.

import AVFoundation
import AVKit
import GeckoView
import UIKit

private final class NativeVideoPlayerViewController: AVPlayerViewController {
    var didDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            didDismiss?()
        }
    }
}

final class NativeVideoPlaybackCoordinator: NSObject, NativeMediaPlayback {
    private weak var host: BrowserViewController?
    private weak var session: GeckoSession?
    private var video: NativeVideo? {
        didSet {
            if #available(iOS 15.0, *), let video {
                (sampleBufferPlaybackDelegate as? NativeVideoPiPPlaybackDelegate)?.video = video
                pictureInPictureController?.requiresLinearPlayback = !NativeVideoTimeline(video).canSeek
                pictureInPictureController?.invalidatePlaybackState()
            }
        }
    }
    private var player: AVPlayer?
    private var playerController: NativeVideoPlayerViewController?
    private var pictureInPictureController: AVPictureInPictureController?
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    // ContentSource holds its playback delegate weakly. Retain one per surface,
    // including throughout AVKit's asynchronous stop transition.
    private var sampleBufferPlaybackDelegate: AnyObject?
    private var retiringSampleBufferPlaybackDelegate: AnyObject?
    private var pipStartPolicy: NativeVideoPiPStartPolicy?
    private var pipRetryNotBefore: TimeInterval = 0
    private let pipDiagnostics = NativeVideoPiPDiagnostics()
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var pollTask: Task<Void, Never>?
    private var stoppingPollTask: Task<Void, Never>?
    private var request: Task<Void, Never>? { didSet { notifyPreparationStateChanged() } }
    private var pipStartTask: Task<Void, Never>? { didSet { notifyPreparationStateChanged() } }
    private var cleanupTask: Task<Void, Never>? { didSet { notifyPreparationStateChanged() } }
    private var cleanupID = UUID()
    private var pipLifecycle = NativeVideoPiPLifecycle() { didSet { notifyPreparationStateChanged() } }
    // AVKit owns a stop animation after stopPictureInPicture() returns. Keep
    // its controller and delegate alive until didStop acknowledges completion.
    private var retiringPictureInPictureController: AVPictureInPictureController?
    private var queuedBegin: (session: GeckoSession, pictureInPicture: Bool, automatic: Bool, target: NativeVideo?)? {
        didSet { notifyPreparationStateChanged() }
    }
    private var isPreparingNativeVideo: Bool {
        request != nil || pipStartTask != nil || cleanupTask != nil || queuedBegin != nil
            || pipLifecycle.phase == .preparing || pipLifecycle.phase == .starting
            || pipLifecycle.phase == .stopping
    }
    private var operationID = UUID()
    private var automaticRequest = false
    private var handoffPrepared = false
    private var nativePlaybackBegan = false
    private var nativePictureInPicture = false
    private var lastNativeRate: Float = 1
    private var interruptedWhilePlaying = false
    private var fullscreenButtons: NativeVideoFullscreenControlsView?
    private weak var fullscreenSession: GeckoSession?
    private var inlineButtons: NativeVideoFullscreenControlsView?
    private weak var inlineSession: GeckoSession?
    private var inlineVideo: NativeVideo?
    private var inlineTimer: Timer?
    private var inlineTimerDeadline: TimeInterval?
    private var inlineDiscoveryTask: Task<Void, Never>?
    private var inlineDiscoveryID: UInt64 = 0
    private var inlineDiscoveryPolicy = NativeVideoInlineDiscoveryPolicy()
    private var inlineMotion = NativeVideoInlineControlsMotion()
    private var inlineGeometryFrame: CGRect?
    private var inlineLayoutFrame: CGRect?
    private var continuation = NativeVideoPiPContinuation()
    private var continuationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var continuationBackgroundID = UUID()
    private var requestedContinuationBackgroundTime = false
    private var parkedEngineContainer: UIView?
    private weak var parkedEngineView: UIView?
    private var retainedSurfaceContainer: UIView?


    init(host: BrowserViewController) {
        self.host = host
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionClosed(_:)),
                                               name: GeckoSession.didCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(videoPreferencesChanged),
                                               name: NativeVideoPreferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inlineDiscoveryBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inlineDiscoveryEnteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        scheduleInlineDiscovery(after: 0.6)
    }

    deinit {
        request?.cancel()
        pipStartTask?.cancel()
        pollTask?.cancel()
        stoppingPollTask?.cancel()
        pollTimer?.invalidate()
        inlineTimer?.invalidate()
        inlineDiscoveryTask?.cancel()
        if continuationBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(continuationBackgroundTask)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func play(session: GeckoSession) {
        begin(session: session, pictureInPicture: false, automatic: false)
    }

    func startPictureInPicture(session: GeckoSession) {
        begin(session: session, pictureInPicture: true, automatic: false)
    }

    func enteredFullscreen(session: GeckoSession) {
        stopInlineDiscoveryTimer()
        invalidateInlineDiscovery()
        inlineMotion.reset()
        removeInlineControls()
        fullscreenSession = session
        installFullscreenButtons()
        begin(session: session, pictureInPicture: false, automatic: true)
    }

    func leftFullscreen(session: GeckoSession) {
        guard fullscreenSession === session else { return }
        fullscreenButtons?.removeFromSuperview()
        fullscreenButtons = nil
        fullscreenSession = nil
        inlineMotion.reset()
        fullscreenDidEnd(session: session)
        wakeInlineDiscovery()
    }

    func selectedSessionDidChange(_ selected: GeckoSession?) {
        inlineMotion.reset()
        invalidateInlineDiscovery()
        inlineDiscoveryPolicy.reset()
        removeInlineControls()
        // Cleanup can still be awaiting a content actor after finish cleared
        // self.session. Always detach a selected parked view before GeckoView
        // embeds it, independently of the playback transaction's identity.
        if let selected, parkedEngineView === selected.engineView {
            releaseParkedVideoEngine()
        }
        if queuedBegin?.session !== selected { queuedBegin = nil }
        if let fullscreenSession, fullscreenSession !== selected {
            leftFullscreen(session: fullscreenSession)
        }
        if let session, session !== selected {
            if ownsGeckoPictureInPicture || nativePictureInPicture {
                parkVideoEngineIfNeeded(session)
            } else {
                finish(restore: true)
            }
        } else if let selected, self.session === selected {
            // GeckoView must receive an unattached view when it embeds a tab.
            releaseParkedVideoEngine()
        }
        scheduleInlineDiscovery(after: 0.1)
    }

    private var ownsGeckoPictureInPicture: Bool {
        continuation.isArmed || pipLifecycle.phase == .preparing
            || pipLifecycle.phase == .starting || pipLifecycle.phase == .active
    }

    func sessionDidNavigate(_ navigating: GeckoSession) {
        if host?.tabManager.selectedTab?.session === navigating {
            invalidateInlineDiscovery()
            inlineMotion.reset()
            removeInlineControls()
            wakeInlineDiscovery()
        }
        if queuedBegin?.session === navigating { queuedBegin = nil }
        guard session === navigating else { return }
        finish(restore: false)
    }

    func contentDidScroll(session: GeckoSession) {
        // The simultaneous pan observer already suppresses discovery for the
        // entire gesture. Gecko's subsequent updates still cover momentum.
        guard !inlineMotion.isDragging else { return }
        inlineScrollActivity(session: session, dragging: nil)
    }

    func mediaPlaybackChanged(session: GeckoSession) {
        guard host?.tabManager.selectedTab?.session === session else { return }
        wakeInlineDiscovery()
    }

    private func wakeInlineDiscovery() {
        inlineDiscoveryPolicy.reset()
        scheduleInlineDiscovery(after: 0.1, preferEarlier: true)
    }

    @objc private func inlineDiscoveryBecameActive() {
        inlineMotion.reset()
        wakeInlineDiscovery()
    }

    @objc private func inlineDiscoveryEnteredBackground() {
        stopInlineDiscoveryTimer()
        invalidateInlineDiscovery()
        inlineButtons?.setScrollSuspended(true)
    }

    private func stopInlineDiscoveryTimer() {
        inlineTimer?.invalidate()
        inlineTimer = nil
        inlineTimerDeadline = nil
    }

    private func scheduleInlineDiscovery(after delay: TimeInterval, preferEarlier: Bool = false) {
        guard UIApplication.shared.applicationState == .active, fullscreenSession == nil else { return }
        let delay = max(0.01, delay)
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        if preferEarlier, let existing = inlineTimerDeadline, existing <= deadline { return }
        stopInlineDiscoveryTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inlineTimer = nil
                self.inlineTimerDeadline = nil
                self.discoverInlineVideo()
            }
        }
        timer.tolerance = min(0.1, delay * 0.1)
        inlineTimer = timer
        inlineTimerDeadline = deadline
        // UIKit tracking should take priority over optional DOM discovery.
        RunLoop.main.add(timer, forMode: .default)
    }

    func contentGeometryWillChange() {
        inlineGeometryTransition(active: true)
    }

    func contentGeometryDidChange() {
        inlineGeometryTransition(active: false)
    }

    private func inlineGeometryTransition(active: Bool) {
        guard fullscreenSession == nil else { return }
        inlineMotion.setTransitioning(active, at: ProcessInfo.processInfo.systemUptime)
        inlineButtons?.setScrollSuspended(true)
        invalidateInlineDiscovery()
        if active { stopInlineDiscoveryTimer() }
        else { scheduleInlineDiscovery(after: NativeVideoInlineControlsMotion.quietInterval) }
    }

    private func invalidateInlineDiscovery() {
        guard inlineDiscoveryTask != nil else { return }
        inlineDiscoveryID &+= 1
        inlineDiscoveryTask?.cancel()
        inlineDiscoveryTask = nil
    }

    private func inlineScrollActivity(session: GeckoSession, dragging: Bool?) {
        guard host?.tabManager.selectedTab?.session === session, fullscreenSession == nil else { return }
        inlineMotion.activity(at: ProcessInfo.processInfo.systemUptime, dragging: dragging)
        inlineButtons?.setScrollSuspended(true)
        invalidateInlineDiscovery()
        if inlineMotion.isDragging { stopInlineDiscoveryTimer() }
        else { scheduleInlineDiscovery(after: NativeVideoInlineControlsMotion.quietInterval, preferEarlier: true) }
    }

    func fullscreenDidEnd(session: GeckoSession) {
        if queuedBegin?.session === session { queuedBegin = nil }
        guard self.session === session, !nativePictureInPicture,
              playerController == nil, !ownsGeckoPictureInPicture else { return }
        finish(restore: true)
    }

    private func begin(session: GeckoSession, pictureInPicture: Bool, automatic: Bool, target: NativeVideo? = nil) {
        guard let host, session.isOpen(), host.tabManager.selectedTab?.session === session else { return }
        invalidateInlineDiscovery()
        scheduleInlineDiscovery(after: 1.5, preferEarlier: true)
        if cleanupTask != nil || retiringPictureInPictureController != nil {
            queueBegin(session: session, pictureInPicture: pictureInPicture, automatic: automatic, target: target)
            if cleanupTask == nil, let retiring = retiringPictureInPictureController {
                retiring.stopPictureInPicture()
                let cleanupIdentifier = UUID()
                cleanupID = cleanupIdentifier
                cleanupTask = Task { @MainActor [weak self] in
                    await self?.waitForRetiringPictureInPicture(retiring)
                    guard self?.cleanupID == cleanupIdentifier else { return }
                    self?.cleanupTask = nil
                    self?.performQueuedBegin()
                }
            }
            return
        }
        if self.session === session, let playerController {
            if playerController.presentingViewController == nil, host.presentedViewController == nil {
                host.present(playerController, animated: true)
            }
            return
        }
        if let current = self.session {
            if current === session, pictureInPicture, pictureInPictureController != nil {
                switch pipLifecycle.phase {
                case .active, .preparing, .starting: return
                case .stopping:
                    queueBegin(session: session, pictureInPicture: true, automatic: automatic, target: target)
                    return
                case .ready: break // Revalidate and reuse the stopped controller.
                }
            } else {
                // A tap while fullscreen's automatic discovery is pending must
                // survive that request's cleanup instead of disappearing.
                guard !automatic else { return }
                queueBegin(session: session, pictureInPicture: pictureInPicture, automatic: false, target: target)
                finish(restore: true)
                return
            }
        }
        guard request == nil, host.presentedViewController == nil else { return }
        if pictureInPicture, !pipLifecycle.prepare() { return }
        let identifier = UUID()
        operationID = identifier
        automaticRequest = automatic
        self.session = session
        if pictureInPicture {
            host.sessionManager.keepSessionActiveForVideo(session)
            pipDiagnostics.reset()
            recordPictureInPicture(.requestBegan)
        }
        request = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer { if operationID == identifier { request = nil } }
            do {
                let selected: NativeVideo
                if let target {
                    guard let exact = try await session.commandNativeVideo(target, command: "status") else {
                        throw PlaybackError.sourceChanged
                    }
                    selected = exact
                } else {
                    selected = try await selectNativeVideo(session: session, identifier: identifier)
                }
                guard isCurrent(identifier, session: session) else {
                    try? await session.commandNativeVideo(selected, command: "release")
                    return
                }
                video = selected
                updateFullscreenControls(for: selected)
                if selected.hasProtectedContent { throw PlaybackError.protectedVideo }
                if pictureInPicture {
                    recordPictureInPicture(.videoSelected)
                    try await beginGeckoPictureInPicture(selected, session: session, identifier: identifier)
                } else if let url = selected.url {
                    try await beginNativePlayer(selected, url: url, session: session, identifier: identifier)
                } else if !automatic {
                    throw PlaybackError.browserStream
                } else {
                    finish(restore: false)
                }
            } catch {
                guard operationID == identifier else { return }
                if pictureInPicture {
                    failPictureInPicture(error)
                } else {
                    finish(restore: true)
                    if !automatic { show(error.localizedDescription, nativePlayerOptions: true) }
                }
            }
        }
    }

    private func queueBegin(session: GeckoSession, pictureInPicture: Bool, automatic: Bool, target: NativeVideo? = nil) {
        // An automatic fullscreen event must never replace an explicit tap.
        guard !automatic || queuedBegin?.automatic != false else { return }
        queuedBegin = (session, pictureInPicture, automatic, target)
    }

    private func notifyPreparationStateChanged() {
        setFullscreenControlsBusy(isPreparingNativeVideo)
        inlineButtons?.setBusy(isPreparingNativeVideo)
    }

    private func performQueuedBegin() {
        guard cleanupTask == nil, retiringPictureInPictureController == nil,
              let pending = queuedBegin else { return }
        queuedBegin = nil
        guard !pending.automatic || fullscreenSession === pending.session else { return }
        begin(session: pending.session, pictureInPicture: pending.pictureInPicture, automatic: pending.automatic, target: pending.target)
    }

    private func selectNativeVideo(session: GeckoSession, identifier: UUID) async throws -> NativeVideo {
        let deadline = Date().addingTimeInterval(5)
        while true {
            guard isCurrent(identifier, session: session) else { throw PlaybackError.cancelled }
            if let selected = try await session.nativeVideo() { return selected }
            // YouTube can enter fullscreen before metadata or its <video>
            // exists. Keep the explicit tap alive while that player loads.
            guard !automaticRequest, Date() < deadline else { throw PlaybackError.noVideo }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func isCurrent(_ identifier: UUID, session: GeckoSession) -> Bool {
        operationID == identifier && !Task.isCancelled && session.isOpen()
            && self.session === session
            && (host?.tabManager.selectedTab?.session === session || ownsGeckoPictureInPicture)
            && (!automaticRequest || fullscreenSession === session)
    }

    private func beginNativePlayer(_ selected: NativeVideo, url: URL, session: GeckoSession,
                                   identifier: UUID) async throws {
        // Use public AVURLAsset options. Browser cookies never leave Gecko.
        var options: [String: Any] = [:]
        if #available(iOS 16.0, *), !selected.userAgent.isEmpty {
            options[AVURLAssetHTTPUserAgentKey] = selected.userAgent
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.isMuted = selected.muted
        player.volume = Float(selected.volume)
        self.player = player
        lastNativeRate = Float(selected.playbackRate > 0 ? selected.playbackRate : 1)

        // Do not pause the webpage until the media is actually ready to play.
        // A protected/authenticated/unsupported source falls back without audio loss.
        let ready = try await waitUntilReady(item, identifier: identifier)
        guard ready, isCurrent(identifier, session: session) else { throw PlaybackError.cancelled }
        session.mediaSession.playbackOverride = self
        // Even a timed-out prepare might reach the content process later.
        // Cleanup must attempt the matching rollback in that case too.
        handoffPrepared = true
        guard let prepared = try await session.commandNativeVideo(selected, command: "prepare") else {
            throw PlaybackError.sourceChanged
        }
        guard isCurrent(identifier, session: session) else {
            // finish() owns rollback, including when it is waiting for this
            // request to retire. Restoring here would consume the token twice.
            throw PlaybackError.cancelled
        }
        video = prepared
        handoffPrepared = true
        lastNativeRate = Float(prepared.playbackRate > 0 ? prepared.playbackRate : 1)
        try activateAudio()
        let position = CMTime(seconds: max(0, prepared.currentTime), preferredTimescale: 600)
        await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        guard isCurrent(identifier, session: session), let host, host.presentedViewController == nil else {
            throw PlaybackError.cancelled
        }

        let controller = NativeVideoPlayerViewController()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = false
        if #available(iOS 14.2, *) { controller.canStartPictureInPictureAutomaticallyFromInline = true }
        controller.modalPresentationStyle = .fullScreen
        controller.didDismiss = { [weak self, weak controller] in
            // AVKit starts PiP as it dismisses fullscreen. Wait until its delegate
            // has recorded that transition before deciding to return to Gecko.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, operationID == identifier,
                      playerController === controller, !nativePictureInPicture else { return }
                finish(restore: true)
            }
        }
        playerController = controller
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, operationID == identifier, self.player?.currentItem === item else { return }
                finish(restore: true) { [weak self] in
                    self?.show(NSLocalizedString("Native playback failed. Playback has returned to the webpage.", comment: ""),
                               nativePlayerOptions: true)
                }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, operationID == identifier else { return }
                publishNativeState()
            }
        }
        session.mediaSessionDelegate?.onActivated(session: session)
        session.mediaSessionDelegate?.onFeatures(session: session, features: [.play, .pause, .seekTo, .seekForward, .seekBackward])
        host.present(controller, animated: true) { [weak self] in
            guard let self, self.player === player else { return }
            nativePlaybackBegan = true
            if !prepared.paused { player.playImmediately(atRate: lastNativeRate) }
            publishNativeState()
        }
        startPolling()
    }

    private func waitUntilReady(_ item: AVPlayerItem, identifier: UUID) async throws -> Bool {
        for _ in 0..<150 {
            if Task.isCancelled || operationID != identifier { throw PlaybackError.cancelled }
            switch item.status {
            case .readyToPlay: return true
            case .failed: throw PlaybackError.unplayable
            default: break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PlaybackError.unplayable
    }

    private func beginGeckoPictureInPicture(_ selected: NativeVideo, session: GeckoSession,
                                           identifier: UUID) async throws {
        guard #available(iOS 15.0, *), AVPictureInPictureController.isPictureInPictureSupported() else {
            throw PlaybackError.unsupportedPictureInPicture
        }
        var selected = selected
        var matchingLayer: AVSampleBufferDisplayLayer?
        // Page layout and Gecko's compositor commit independently. Wait
        // for that exact video's one unambiguous layer instead of rejecting a
        // valid first tap before the first fullscreen frame arrives.
        let layerDeadline = ProcessInfo.processInfo.systemUptime + 4
        recordPictureInPicture(.waitingForLayer)
        while ProcessInfo.processInfo.systemUptime < layerDeadline {
            guard isCurrent(identifier, session: session) else { throw PlaybackError.cancelled }
            guard !selected.hasProtectedContent else { throw PlaybackError.protectedVideo }
            if selected.visibleArea > 0,
               let layer = session.nativeVideoDisplayLayer(for: selected) {
                matchingLayer = layer
                break
            }
            // Inline PiP uses Gecko's iOS video surface directly. Never change
            // the document's fullscreen state to acquire this layer.
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let updated = try await session.commandNativeVideo(selected, command: "status") else {
                throw PlaybackError.sourceChanged
            }
            selected = updated
            video = updated
        }
        guard let layer = matchingLayer else { throw PlaybackError.ambiguousVideoLayer }
        guard isCurrent(identifier, session: session) else { throw PlaybackError.cancelled }
        video = selected
        _ = try await session.commandNativeVideo(selected, command: "follow", values: ["enabled": true])
        guard isCurrent(identifier, session: session) else {
            _ = try? await session.commandNativeVideo(selected, command: "follow", values: ["enabled": false])
            throw PlaybackError.cancelled
        }
        continuation.arm()
        try activateAudio()
        configurePictureInPicture(layer: layer, video: selected)
        host?.sessionManager.keepSessionActiveForVideo(session)
        pipStartPolicy = NativeVideoPiPStartPolicy(now: ProcessInfo.processInfo.systemUptime)
        pipRetryNotBefore = 0
        recordPictureInPicture(.waitingForReadiness)
        pipStartTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            var nextStatus = ProcessInfo.processInfo.systemUptime
            do {
                while isCurrent(identifier, session: session) {
                    if pipLifecycle.phase == .active { return }
                    var visibleLayer: AVSampleBufferDisplayLayer?
                    let now = ProcessInfo.processInfo.systemUptime
                    if pipLifecycle.phase == .preparing, now >= pipRetryNotBefore {
                        if now >= nextStatus {
                            guard let target = video,
                                  let updated = try await session.commandNativeVideo(target, command: "status") else {
                                throw PlaybackError.sourceChanged
                            }
                            guard isCurrent(identifier, session: session) else { return }
                            guard !updated.hasProtectedContent else { throw PlaybackError.protectedVideo }
                            video = updated
                            updateFullscreenControls(for: updated)
                            nextStatus = ProcessInfo.processInfo.systemUptime + 0.3
                        }
                        if let current = video,
                           let surface = session.nativeVideoDisplayLayer(for: current) {
                            visibleLayer = surface
                            // Rotation/fullscreen can replace the surface after
                            // discovery. Rebind only before a start is issued.
                            configurePictureInPicture(layer: surface, video: current)
                        }
                    }
                    guard var policy = pipStartPolicy else { return }
                    let decision = policy.observe(
                        surfaceID: visibleLayer.map(ObjectIdentifier.init),
                        frameReady: visibleLayer.map(isPictureInPictureFrameReady) ?? false,
                        systemPossible: pictureInPictureController?.isPictureInPicturePossible == true,
                        now: ProcessInfo.processInfo.systemUptime)
                    pipStartPolicy = policy
                    switch decision {
                    case .wait: break
                    case .start:
                        pipLifecycle.willStart()
                        recordPictureInPicture(.startRequested)
                        pictureInPictureController?.startPictureInPicture()
                    case .failure(let failure):
                        failPictureInPicture(
                            failure == .readinessTimedOut ? PlaybackError.videoNotReady : PlaybackError.pictureInPictureTimedOut,
                            stage: failure == .readinessTimedOut ? .readinessTimedOut : .startTimedOut)
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch is CancellationError {
                // didStart cancels this watchdog after a successful start.
                return
            } catch {
                guard operationID == identifier, !Task.isCancelled, pipLifecycle.phase != .active else { return }
                failPictureInPicture(error)
            }
        }
    }

    @available(iOS 15.0, *)
    private func configurePictureInPicture(layer: AVSampleBufferDisplayLayer, video: NativeVideo) {
        guard sampleBufferLayer !== layer || pictureInPictureController == nil else {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = continuation.isArmed
            return
        }
        let playbackDelegate = NativeVideoPiPPlaybackDelegate(
            layer: layer, video: video,
            setPlaying: { [weak self] controller, playing in
                self?.pictureInPictureController(controller, setPlaying: playing)
            }, skip: { [weak self] controller, interval, completion in
                guard let self else { completion(); return }
                pictureInPictureController(controller, skipByInterval: interval, completion: completion)
            })
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: playbackDelegate)
        // AVKit supports replacing a running controller's source once the next
        // layer is ready. Retain the previous delegate until the assignment.
        let previousDelegate = sampleBufferPlaybackDelegate
        sampleBufferPlaybackDelegate = playbackDelegate
        sampleBufferLayer = layer
        if let controller = pictureInPictureController {
            controller.contentSource = source
        } else {
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pictureInPictureController = controller
            recordPictureInPicture(.controllerCreated)
        }
        withExtendedLifetime(previousDelegate) {}
        retainedSurfaceContainer?.removeFromSuperview()
        retainedSurfaceContainer = nil
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = continuation.isArmed
        pictureInPictureController?.requiresLinearPlayback = !NativeVideoTimeline(video).canSeek
        pictureInPictureController?.invalidatePlaybackState()
    }

    @available(iOS 15.0, *)
    private func isPictureInPictureFrameReady(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        guard layer.superlayer != nil, !layer.isHidden, layer.opacity > 0 else { return false }
        if #available(iOS 17.0, *) {
            guard layer.sampleBufferRenderer.status == .rendering,
                  !layer.sampleBufferRenderer.requiresFlushToResumeDecoding else { return false }
        } else {
            guard layer.status == .rendering, !layer.requiresFlushToResumeDecoding else { return false }
        }
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return true
    }

    private func activateAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        // Playback already supports AirPlay. Explicit allowAirPlay is only
        // valid with playAndRecord and can fail here with OSStatus -50.
        try audio.setCategory(.playback, mode: .moviePlayback, options: [])
        try audio.setActive(true)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
        pollInFlight = false
    }

    private func poll() {
        guard !pollInFlight, let session, let video else { return }
        let identifier = operationID
        pollInFlight = true
        pollTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if operationID == identifier {
                    pollInFlight = false
                    pollTask = nil
                }
            }
            do {
                let updated = try await session.commandNativeVideo(video,
                    command: continuation.isArmed ? "continue" : "status")
                guard operationID == identifier else {
                    // A successor may rotate its token while PiP closes. Clear
                    // its lease using the returned token before discarding it.
                    if let updated {
                        _ = try? await session.commandNativeVideo(updated, command: "follow", values: ["enabled": false])
                    }
                    return
                }
                // Continue can rotate its token, including before a terminal
                // protected/end check. Cleanup must retire that new identity.
                if let updated { self.video = updated }
                if continuation.isArmed {
                    // Metadata alone cannot end a background loading lease.
                    // After an ended/source gap, observe the same successor
                    // actually advancing before declaring playback resumed.
                    let advancing = updated.map {
                        $0.token == video.token && !$0.paused && $0.currentTime > video.currentTime + 0.01
                    } ?? false
                    let available = continuation.isPlaybackReady(readyState: updated?.readyState ?? 0,
                        sameTarget: updated?.token == video.token, advancing: advancing)
                    switch continuation.observe(available: available, ended: updated?.ended ?? false,
                                                now: ProcessInfo.processInfo.systemUptime) {
                    case .expired:
                        finish(restore: false)
                        return
                    case .waiting:
                        requestContinuationBackgroundTime()
                        retainLastPictureInPictureFrame()
                    case .ready:
                        endContinuationBackgroundTime()
                        requestedContinuationBackgroundTime = false
                    }
                } else if updated == nil {
                    finish(restore: false)
                    return
                }
                guard let updated else { return }
                guard !updated.hasProtectedContent else {
                    finish(restore: false)
                    return
                }
                updateFullscreenControls(for: updated)
                if player != nil { publishNativeState() }
                if #available(iOS 15.0, *), let controller = pictureInPictureController {
                    // Unknown geometry (for example an iframe hidden by the
                    // site) may describe the owner while another video's layer
                    // is visible. Keep the known source; never adopt that layer.
                    if updated.readyState >= 2, updated.visibleRect != nil,
                       let layer = session.nativeVideoDisplayLayer(for: updated, allowsOffscreen: true),
                       layer !== sampleBufferLayer, isPictureInPictureFrameReady(layer) {
                        configurePictureInPicture(layer: layer, video: updated)
                    } else if sampleBufferLayer?.superlayer == nil {
                        retainLastPictureInPictureFrame()
                    }
                    controller.requiresLinearPlayback = !NativeVideoTimeline(updated).canSeek
                    controller.invalidatePlaybackState()
                }
            } catch {
                guard operationID == identifier else { return }
                if continuation.isArmed,
                   continuation.observe(available: false, ended: false,
                                        now: ProcessInfo.processInfo.systemUptime) != .expired {
                    requestContinuationBackgroundTime()
                    retainLastPictureInPictureFrame()
                    return
                }
                finish(restore: false)
            }
        }
    }

    private func requestContinuationBackgroundTime() {
        guard continuation.isArmed, !requestedContinuationBackgroundTime,
              UIApplication.shared.applicationState != .active else { return }
        // One bounded request bridges the gap after audio ends. AVKit may keep
        // executing itself, but UIKit does not promise sixty seconds here.
        requestedContinuationBackgroundTime = true
        let identifier = UUID()
        continuationBackgroundID = identifier
        continuationBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Video Autoplay Continuation"
        ) { [weak self] in
            guard let self, self.continuationBackgroundID == identifier else { return }
            self.endContinuationBackgroundTime()
            if self.continuation.isArmed, self.continuation.waitingSince != nil {
                self.finish(restore: false)
            }
        }
    }

    private func endContinuationBackgroundTime() {
        continuationBackgroundID = UUID()
        guard continuationBackgroundTask != .invalid else { return }
        let task = continuationBackgroundTask
        continuationBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func publishNativeState() {
        guard let session, let player else { return }
        if player.rate > 0 { lastNativeRate = player.rate }
        if player.rate == 0 {
            session.mediaSessionDelegate?.onPlaybackPaused(session: session)
        } else {
            session.mediaSessionDelegate?.onPlaybackPlaying(session: session)
        }
        let duration = player.currentItem?.duration.seconds ?? 0
        let position = player.currentTime().seconds
        session.mediaSessionDelegate?.onPositionState(session: session, state: .init(
            duration: duration.isFinite ? duration : 0,
            playbackRate: Double(player.rate), position: position.isFinite ? position : 0))
    }

    private func finish(restore: Bool, afterPlayerDismissal: (() -> Void)? = nil) {
        guard session != nil || request != nil || player != nil || pictureInPictureController != nil else {
            afterPlayerDismissal?()
            return
        }
        let pendingCleanup = cleanupTask
        let previousSession = session
        let previousVideo = video
        let previousPlayer = player
        let previousPlayerController = playerController
        let wasPrepared = handoffPrepared
        let didBeginPlayback = nativePlaybackBegan
        let pendingRequest = request
        let pendingPiPStart = pipStartTask
        let pendingPoll = pollTask ?? stoppingPollTask
        stoppingPollTask = nil
        let previousPiPController = pictureInPictureController
        let previousPlaybackDelegate = sampleBufferPlaybackDelegate
        continuation.disarm()
        endContinuationBackgroundTime()
        requestedContinuationBackgroundTime = false
        let piPNeedsStop = pipLifecycle.needsSystemStop
        let currentTime = previousPlayer?.currentTime().seconds
        let paused = previousPlayer.map { $0.rate == 0 }
        let rate = previousPlayer.map { $0.rate > 0 ? Double($0.rate) : Double(lastNativeRate) }
        operationID = UUID()
        request?.cancel()
        request = nil
        pipStartTask?.cancel()
        pipStartTask = nil
        pipStartPolicy = nil
        pipRetryNotBefore = 0
        itemObservation = nil
        playbackObservation = nil
        stopPolling()
        playerController?.didDismiss = nil
        playerController?.delegate = nil
        playerController = nil
        pictureInPictureController = nil
        sampleBufferPlaybackDelegate = nil
        pipLifecycle.didStop()
        if let previousPiPController {
            if piPNeedsStop || previousPiPController.isPictureInPictureActive {
                retiringPictureInPictureController = previousPiPController
                retiringSampleBufferPlaybackDelegate = previousPlaybackDelegate
                previousPiPController.stopPictureInPicture()
            } else {
                previousPiPController.delegate = nil
                if #available(iOS 15.0, *) { previousPiPController.contentSource = nil }
            }
        }
        sampleBufferLayer = nil
        previousPlayer?.pause()
        previousPlayer?.replaceCurrentItem(with: nil)
        player = nil
        session = nil
        video = nil
        handoffPrepared = false
        nativePlaybackBegan = false
        automaticRequest = false
        interruptedWhilePlaying = false
        nativePictureInPicture = false
        if let previousSession {
            previousSession.mediaSession.playbackOverride = nil
            host?.sessionManager.releaseSessionActiveForVideo(previousSession)
        }
        let cleanupIdentifier = UUID()
        cleanupID = cleanupIdentifier
        cleanupTask = Task { @MainActor [weak self] in
            await pendingCleanup?.value
            // Retiring requests may still be returning from a Gecko actor or
            // rolling back prepare. Finish them before acquiring another token.
            await pendingRequest?.value
            await pendingPiPStart?.value
            await pendingPoll?.value
            if let previousPiPController {
                await self?.waitForRetiringPictureInPicture(previousPiPController)
            }
            defer {
                if self?.cleanupID == cleanupIdentifier {
                    self?.releaseParkedVideoEngine()
                    self?.retainedSurfaceContainer?.removeFromSuperview()
                    self?.retainedSurfaceContainer = nil
                    self?.cleanupTask = nil
                    self?.performQueuedBegin()
                }
            }
            guard let previousSession, let previousVideo, previousSession.isOpen() else { return }
            _ = try? await previousSession.commandNativeVideo(previousVideo, command: "follow", values: ["enabled": false])
            if restore && wasPrepared {
                var values: [String: Any?] = [:]
                if didBeginPlayback {
                    values["paused"] = paused ?? previousVideo.paused
                    values["playbackRate"] = rate ?? previousVideo.playbackRate
                    values["muted"] = previousPlayer?.isMuted
                    values["volume"] = previousPlayer.map { Double($0.volume) }
                    if let currentTime, currentTime.isFinite { values["currentTime"] = max(0, currentTime) }
                }
                if let restored = try? await previousSession.commandNativeVideo(previousVideo, command: "restore", values: values) {
                    if restored.paused {
                        previousSession.mediaSessionDelegate?.onPlaybackPaused(session: previousSession)
                    } else {
                        previousSession.mediaSessionDelegate?.onPlaybackPlaying(session: previousSession)
                    }
                } else {
                    previousSession.mediaSessionDelegate?.onPlaybackNone(session: previousSession)
                }
            } else {
                try? await previousSession.commandNativeVideo(previousVideo, command: "release")
                if wasPrepared { previousSession.mediaSessionDelegate?.onPlaybackNone(session: previousSession) }
            }
        }
        if previousPlayerController?.presentingViewController != nil {
            previousPlayerController?.dismiss(animated: true, completion: afterPlayerDismissal)
        } else {
            afterPlayerDismissal?()
        }
    }

    private func waitForRetiringPictureInPicture(_ controller: AVPictureInPictureController) async {
        for _ in 0..<50 {
            guard retiringPictureInPictureController === controller else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Normally didStop completes the teardown. If AVKit never began a
        // transition, it may send no stop callback; release only once inactive.
        if retiringPictureInPictureController === controller, !controller.isPictureInPictureActive {
            releaseRetiringPictureInPicture(controller)
        } else if retiringPictureInPictureController === controller {
            let explicitRetry = queuedBegin?.automatic == false
            queuedBegin = nil
            if explicitRetry {
                show(NSLocalizedString("Picture in Picture is still closing. Try again in a moment.", comment: ""))
            }
        }
    }

    private func releaseRetiringPictureInPicture(_ controller: AVPictureInPictureController) {
        guard retiringPictureInPictureController === controller else { return }
        controller.delegate = nil
        if #available(iOS 15.0, *) { controller.contentSource = nil }
        retiringPictureInPictureController = nil
        retiringSampleBufferPlaybackDelegate = nil
        performQueuedBegin()
    }

    func handleNativeMediaCommand(_ command: NativeMediaCommand) {
        guard nativePlaybackBegan, let player else { return }
        switch command {
        case .play: player.playImmediately(atRate: lastNativeRate)
        case .pause: player.pause()
        case .stop: player.pause()
        case .seekForward(let offset): seekNative(to: player.currentTime().seconds + (offset > 0 ? offset : 15))
        case .seekBackward(let offset): seekNative(to: player.currentTime().seconds - (offset > 0 ? offset : 15))
        case .seekTo(let time): seekNative(to: time)
        case .mute(let muted): player.isMuted = muted
        case .nextTrack, .previousTrack: break
        }
        publishNativeState()
    }

    private func seekNative(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        var target = max(0, seconds)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite { target = min(target, duration) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    @objc private func sessionClosed(_ notification: Notification) {
        guard let closed = notification.object as? GeckoSession else { return }
        if fullscreenSession === closed { leftFullscreen(session: closed) }
        if session === closed { finish(restore: false) }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let player,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            interruptedWhilePlaying = player.rate > 0
            player.pause()
        case .ended:
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if interruptedWhilePlaying && shouldResume { player.playImmediately(atRate: lastNativeRate) }
            interruptedWhilePlaying = false
        @unknown default: break
        }
    }

    private func discoverInlineVideo() {
        guard UIApplication.shared.applicationState == .active, fullscreenSession == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard inlineMotion.canRefresh(at: now) else {
            if let delay = inlineMotion.delayUntilRefresh(at: now) { scheduleInlineDiscovery(after: delay) }
            return
        }
        guard inlineDiscoveryTask == nil else { return } // Its completion schedules the next search.
        guard !isPreparingNativeVideo,
              let host, host.viewIfLoaded?.window != nil,
              host.presentedViewController == nil,
              let selected = host.tabManager.selectedTab?.session, selected.isOpen(),
              selected.engineView?.window != nil else {
            scheduleInlineDiscovery(after: 1.5)
            return
        }
        inlineDiscoveryID &+= 1
        let identifier = inlineDiscoveryID
        let geometryRevision = inlineMotion.revision
        // An owning PiP target stays pinned, but its pre-scroll descriptor may
        // be stale. Query fresh geometry without selecting a different video.
        let pinned = session === selected && ownsGeckoPictureInPicture ? video : nil
        inlineDiscoveryTask = Task { @MainActor [weak self, weak selected] in
            guard let self else { return }
            defer {
                if inlineDiscoveryID == identifier {
                    inlineDiscoveryTask = nil
                    let delay = inlineDiscoveryPolicy.delayAfterResponse(hasVideo: inlineVideo != nil,
                        controlsVisible: inlineButtons?.isPresentingControls == true)
                    scheduleInlineDiscovery(after: delay, preferEarlier: true)
                }
            }
            guard let selected else { return }
            do {
                let candidate: NativeVideo?
                if let pinned {
                    candidate = try await selected.commandNativeVideo(pinned, command: "status")
                } else {
                    candidate = try await selected.nativeVideo()
                }
                guard !Task.isCancelled, inlineDiscoveryID == identifier,
                      inlineMotion.canApplyGeometry(requestedAt: geometryRevision,
                                                    now: ProcessInfo.processInfo.systemUptime),
                      host.tabManager.selectedTab?.session === selected,
                      fullscreenSession == nil else { return }
                if let candidate { updateInlineControls(candidate, session: selected) }
                else { removeInlineControls() }
            } catch {
                guard inlineDiscoveryID == identifier else { return }
                removeInlineControls()
            }
        }
    }

    private func updateInlineControls(_ selected: NativeVideo, session: GeckoSession) {
        guard !selected.isFullscreen, !selected.hasProtectedContent,
              selected.visibleRect != nil, selected.visibleArea > 0,
              let host, host.tabManager.selectedTab?.session === session,
              fullscreenSession == nil else {
            removeInlineControls()
            return
        }
        if inlineSession !== session { removeInlineControls() }
        guard let geometry = inlineVideoFrame(selected, session: session, host: host) else {
            removeInlineControls()
            return
        }
        if let previous = inlineGeometryFrame,
           abs(previous.minX - geometry.minX) > 2 || abs(previous.minY - geometry.minY) > 2
            || abs(previous.width - geometry.width) > 2 || abs(previous.height - geometry.height) > 2 {
            // Includes nested-frame scrolling or page layout shifts for which
            // Gecko's top-level scroll delegate may not emit an event.
            inlineGeometryFrame = geometry
            inlineScrollActivity(session: session, dragging: nil)
            return
        }
        let geometryChanged = inlineLayoutFrame != geometry
        inlineGeometryFrame = geometry
        inlineLayoutFrame = geometry
        if inlineButtons == nil {
            let controls = NativeVideoFullscreenControlsView(
                pictureInPicture: { [weak self, weak session] in
                    guard let self, let session else { return }
                    guard let target = self.inlineVideo else { return }
                    self.begin(session: session, pictureInPicture: true, automatic: false, target: target)
                }, nativePlayback: {})
            controls.isInline = true
            controls.scrollActivity = { [weak self, weak session] dragging in
                guard let session else { return }
                self?.inlineScrollActivity(session: session, dragging: dragging)
            }
            controls.scrollContentFrameProvider = { [weak host, weak session] in
                guard let host, let engine = session?.engineView else { return nil }
                return host.view.convert(engine.bounds, from: engine)
            }
            controls.onReveal = { [weak self] in self?.wakeInlineDiscovery() }
            controls.videoFrameProvider = { [weak self, weak host, weak session] in
                guard let self, let host, let session, let selected = self.inlineVideo else { return nil }
                return self.inlineVideoFrame(selected, session: session, host: host)
            }
            controls.accessibilityIdentifier = "native-video-inline-controls"
            controls.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(controls)
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                controls.topAnchor.constraint(equalTo: host.view.topAnchor),
                controls.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
            ])
            inlineButtons = controls
            inlineSession = session
        }
        inlineVideo = selected
        inlineButtons?.videoSize = CGSize(width: selected.width, height: selected.height)
        inlineButtons?.setScrollSuspended(false)
        inlineButtons?.setBusy(isPreparingNativeVideo)
        if geometryChanged { inlineButtons?.setNeedsLayout() }
    }

    private func inlineVideoFrame(_ selected: NativeVideo, session: GeckoSession,
                                  host: BrowserViewController) -> CGRect? {
        guard let engine = session.engineView, let rect = selected.visibleRect,
              selected.viewportWidth > 0, selected.viewportHeight > 0 else { return nil }
        let scaleX = engine.bounds.width / selected.viewportWidth
        let scaleY = engine.bounds.height / selected.viewportHeight
        let frame = CGRect(x: engine.bounds.minX + rect.minX * scaleX,
                           y: engine.bounds.minY + rect.minY * scaleY,
                           width: rect.width * scaleX, height: rect.height * scaleY)
        return host.view.convert(frame, from: engine)
    }

    private func removeInlineControls() {
        inlineButtons?.removeFromSuperview()
        inlineButtons = nil
        inlineSession = nil
        inlineVideo = nil
        inlineGeometryFrame = nil
        inlineLayoutFrame = nil
    }

    private func parkVideoEngineIfNeeded(_ session: GeckoSession) {
        guard parkedEngineContainer == nil, let host, let engine = session.engineView,
              engine.window != nil else { return }
        let frame = host.view.convert(engine.bounds, from: engine)
        let parking = UIView(frame: frame)
        parking.isUserInteractionEnabled = false
        parking.clipsToBounds = true
        // It stays in the same window behind browser content. Hiding it or
        // setting alpha to zero would stop the compositor's source frames.
        host.view.insertSubview(parking, at: 0)
        engine.removeFromSuperview()
        engine.translatesAutoresizingMaskIntoConstraints = true
        engine.frame = parking.bounds
        engine.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parking.addSubview(engine)
        parkedEngineContainer = parking
        parkedEngineView = engine
    }

    private func releaseParkedVideoEngine() {
        parkedEngineView?.removeFromSuperview()
        parkedEngineView = nil
        parkedEngineContainer?.removeFromSuperview()
        parkedEngineContainer = nil
    }

    private func retainLastPictureInPictureFrame() {
        guard let layer = sampleBufferLayer, layer.superlayer == nil,
              let host, host.viewIfLoaded?.window != nil else { return }
        let holder = retainedSurfaceContainer ?? UIView(frame: host.view.bounds)
        if holder.superview == nil {
            holder.isUserInteractionEnabled = false
            holder.clipsToBounds = true
            host.view.insertSubview(holder, at: 0)
            retainedSurfaceContainer = holder
        }
        // Keep the last displayed frame attached during the player's loading
        // gap. A ready successor replaces the running controller's source.
        if layer.bounds.isEmpty { layer.frame = holder.bounds }
        holder.layer.addSublayer(layer)
    }

    private func installFullscreenButtons() {
        guard fullscreenButtons == nil, let host else { return }
        let controls = NativeVideoFullscreenControlsView(
            pictureInPicture: { [weak self] in self?.fullscreenPictureInPicture() },
            nativePlayback: { [weak self] in self?.fullscreenNativePlayer() })
        controls.showsNativePlayerButton = NativeVideoPreferences.showsNativePlayerButton
        controls.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: host.view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        fullscreenButtons = controls
        controls.setBusy(isPreparingNativeVideo)
    }

    private func updateFullscreenControls(for selected: NativeVideo) {
        guard let controls = fullscreenButtons else { return }
        controls.showsNativePlayerButton = NativeVideoPreferences.showsNativePlayerButton
        controls.videoSize = CGSize(width: selected.width, height: selected.height)
        // Reading the compositor surface's frame needs no additional DOM
        // request and keeps controls aligned with the real video on rotation.
        controls.videoFrameProvider = { [weak self] in
            guard let self, let host, let fullscreenSession,
                  let engine = fullscreenSession.engineView,
                  let surface = fullscreenSession.nativeVideoDisplayLayer(for: selected) else { return nil }
            let frame = engine.layer.convert(surface.bounds, from: surface)
            return host.view.convert(frame, from: engine)
        }
        controls.setNeedsLayout()
    }

    private func setFullscreenControlsBusy(_ busy: Bool) {
        fullscreenButtons?.setBusy(busy)
    }

    @objc private func fullscreenPictureInPicture() {
        if let fullscreenSession { startPictureInPicture(session: fullscreenSession) }
    }

    @objc private func fullscreenNativePlayer() {
        if let fullscreenSession { play(session: fullscreenSession) }
    }

    private func recordPictureInPicture(_ stage: NativeVideoPiPDiagnostics.Stage, error: Error? = nil) {
        var rendererStatus: Int?
        var frameReady: Bool?
        if #available(iOS 15.0, *), let layer = sampleBufferLayer {
            if #available(iOS 17.0, *) {
                rendererStatus = layer.sampleBufferRenderer.status.rawValue
            } else {
                rendererStatus = layer.status.rawValue
            }
            frameReady = isPictureInPictureFrameReady(layer)
        }
        pipDiagnostics.record(stage, snapshot: .init(
            sourceKind: video.map { $0.url == nil ? .browserManaged : .direct },
            width: video?.width, height: video?.height, duration: video?.duration,
            paused: video?.paused, visibleVideoCount: video?.totalVisibleVideoCount,
            rendererStatus: rendererStatus, frameReady: frameReady,
            possible: pictureInPictureController?.isPictureInPicturePossible,
            phase: .init(rawValue: String(describing: pipLifecycle.phase))), error: error)
    }

    private func failPictureInPicture(_ error: Error, stage: NativeVideoPiPDiagnostics.Stage = .failedToStart) {
        recordPictureInPicture(stage, error: error)
        let details = pipDiagnostics.report(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        finish(restore: false)
        show(error.localizedDescription, details: details)
    }

    @objc private func videoPreferencesChanged() {
        fullscreenButtons?.showsNativePlayerButton = NativeVideoPreferences.showsNativePlayerButton
    }

    private func show(_ message: String, details: String? = nil, nativePlayerOptions: Bool = false) {
        guard let host, host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: NSLocalizedString("Native Video", comment: ""),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        if nativePlayerOptions {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Screen Mirroring…", comment: ""), style: .default) { [weak host, weak alert] _ in
                guard let host, let alert else { return }
                SettingsViewUtils.dismissPresentedAlert(alert, from: host) { [weak host] in
                    guard let host, host.presentedViewController == nil else { return }
                    host.present(NativeVideoScreenMirroring.makeGuide(), animated: true)
                }
            })
            if NativeVideoPreferences.showsNativePlayerButton {
                alert.addAction(UIAlertAction(title: NSLocalizedString("Hide Native Player Button", comment: ""), style: .default) { _ in
                    NativeVideoPreferences.showsNativePlayerButton = false
                })
            }
        }
        if let details {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Copy Details", comment: ""), style: .default) { _ in
                UIPasteboard.general.string = details
            })
        }
        host.present(alert, animated: true)
    }

    private enum PlaybackError: LocalizedError {
        case noVideo, browserStream, protectedVideo, sourceChanged, cancelled
        case unplayable, unsupportedPictureInPicture, ambiguousVideoLayer, videoNotReady, pictureInPictureTimedOut

        var errorDescription: String? {
            switch self {
            case .noVideo: return NSLocalizedString("Start a video on this page, then try again.", comment: "")
            case .browserStream: return NSLocalizedString("This video needs the website’s player. Use Picture in Picture on your phone, or Screen Mirroring for a compatible TV.", comment: "")
            case .protectedVideo: return NSLocalizedString("This protected video cannot be handed to the native player.", comment: "")
            case .unplayable: return NSLocalizedString("Apple’s player could not open this stream. The website may require browser authentication or an unsupported video format. Playback continues on the webpage.", comment: "")
            case .unsupportedPictureInPicture: return NSLocalizedString("Picture in Picture could not start for this video. Keep it playing and try again.", comment: "")
            case .videoNotReady: return NSLocalizedString("The browser has not prepared a video frame for Picture in Picture yet. Keep the video playing, then try again.", comment: "")
            case .pictureInPictureTimedOut: return NSLocalizedString("Picture in Picture did not finish opening. Wait a moment, then try again.", comment: "")
            case .ambiguousVideoLayer: return NSLocalizedString("Keep one video visible and playing, then try Picture in Picture again. Opening it fullscreen can help.", comment: "")
            case .sourceChanged, .cancelled: return NSLocalizedString("The video or page changed. Try again on the current video.", comment: "")
            }
        }
    }
}

extension NativeVideoPlaybackCoordinator: AVPlayerViewControllerDelegate {
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard playerController === playerViewController else { return }
        nativePictureInPicture = true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              failedToStartPictureInPictureWithError error: Error) {
        guard playerController === playerViewController else { return }
        nativePictureInPicture = false
        if playerViewController.presentingViewController == nil { finish(restore: true) }
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard playerController === playerViewController else { return }
        nativePictureInPicture = false
        if playerViewController.presentingViewController == nil { finish(restore: true) }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard playerController === playerViewController,
              let host, host.presentedViewController == nil, session?.isOpen() == true else {
            completionHandler(false)
            return
        }
        host.present(playerViewController, animated: true) { completionHandler(true) }
    }
}

extension NativeVideoPlaybackCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if retiringPictureInPictureController === pictureInPictureController {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        guard self.pictureInPictureController === pictureInPictureController else { return }
        pipLifecycle.willStart()
        recordPictureInPicture(.willStart)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if retiringPictureInPictureController === pictureInPictureController {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        guard self.pictureInPictureController === pictureInPictureController else { return }
        pipLifecycle.didStart()
        recordPictureInPicture(.didStart)
        pipStartPolicy = nil
        pipStartTask?.cancel()
        pipStartTask = nil
        startPolling()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        if retiringPictureInPictureController === pictureInPictureController {
            releaseRetiringPictureInPicture(pictureInPictureController)
            return
        }
        guard self.pictureInPictureController === pictureInPictureController else { return }
        recordPictureInPicture(.failedToStart, error: error)
        if var policy = pipStartPolicy,
           policy.didFailToStart(now: ProcessInfo.processInfo.systemUptime) {
            pipStartPolicy = policy
            // AVKit has explicitly finished this failed start. Discard the
            // failed controller, refresh the exact target and try once more.
            pictureInPictureController.delegate = nil
            if #available(iOS 15.0, *) { pictureInPictureController.contentSource = nil }
            self.pictureInPictureController = nil
            sampleBufferPlaybackDelegate = nil
            sampleBufferLayer = nil
            pipLifecycle.didStop()
            _ = pipLifecycle.prepare()
            pipRetryNotBefore = ProcessInfo.processInfo.systemUptime + 0.35
            recordPictureInPicture(.retryScheduled)
            return
        }
        pipLifecycle.didStop()
        failPictureInPicture(error)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        pipLifecycle.willStop()
        endContinuationBackgroundTime()
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        recordPictureInPicture(.willStop)
        pipStartPolicy = nil
        pipStartTask?.cancel()
        pipStartTask = nil
        operationID = UUID()
        if let pollTask { stoppingPollTask = pollTask }
        stopPolling()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if retiringPictureInPictureController === pictureInPictureController {
            releaseRetiringPictureInPicture(pictureInPictureController)
            return
        }
        guard self.pictureInPictureController === pictureInPictureController else { return }
        recordPictureInPicture(.didStop)
        let previousPoll = pollTask ?? stoppingPollTask
        stoppingPollTask = nil
        let previousCleanup = cleanupTask
        let stoppedSession = session
        let stoppedVideo = video
        operationID = UUID()
        pipStartTask?.cancel()
        pipStartTask = nil
        stopPolling()
        pipLifecycle.didStop()
        pipStartPolicy = nil
        continuation.disarm()
        endContinuationBackgroundTime()
        requestedContinuationBackgroundTime = false
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        if let stoppedSession { host?.sessionManager.releaseSessionActiveForVideo(stoppedSession) }
        let cleanupIdentifier = UUID()
        cleanupID = cleanupIdentifier
        cleanupTask = Task { @MainActor [weak self] in
            // A late continue response may rotate its target. It must finish
            // disarming before another manual start can acquire that token.
            await previousCleanup?.value
            await previousPoll?.value
            if let stoppedSession, let stoppedVideo, stoppedSession.isOpen() {
                _ = try? await stoppedSession.commandNativeVideo(stoppedVideo, command: "follow", values: ["enabled": false])
            }
            guard let self, cleanupID == cleanupIdentifier else { return }
            releaseParkedVideoEngine()
            retainedSurfaceContainer?.removeFromSuperview()
            retainedSurfaceContainer = nil
            cleanupTask = nil
            performQueuedBegin()
        }
        // The inactive controller remains available for a later explicit start.
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard self.pictureInPictureController === pictureInPictureController,
              let host, let session, session.isOpen() else {
            completionHandler(false)
            return
        }
        if host.tabManager.selectedTab?.session !== session {
            if let index = host.tabManager.regularTabs.firstIndex(where: { $0.session === session }) {
                host.tabManager.selectTab(at: index, mode: .regular)
            } else if let index = host.tabManager.privateTabs.firstIndex(where: { $0.session === session }) {
                host.tabManager.selectTab(at: index, mode: .private)
            }
        }
        completionHandler(host.tabManager.selectedTab?.session === session && host.viewIfLoaded?.window != nil)
    }
}

@available(iOS 15.0, *)
private extension NativeVideoPlaybackCoordinator {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.pictureInPictureController === pictureInPictureController,
              continuation.isArmed, let session, let video else { return }
        let identifier = operationID
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                guard let updated = try await session.commandNativeVideo(video, command: playing ? "play" : "pause"),
                      operationID == identifier, self.pictureInPictureController === pictureInPictureController,
                      self.video?.token == video.token, updated.token == video.token else { return }
                self.video = updated
                pictureInPictureController.invalidatePlaybackState()
            } catch {
                guard operationID == identifier else { return }
                if continuation.isArmed { poll(); return }
                finish(restore: false)
                show(error.localizedDescription)
            }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        guard self.pictureInPictureController === pictureInPictureController,
              continuation.isArmed, let session, let video, skipInterval.seconds.isFinite,
              NativeVideoTimeline(video).canSeek else { completionHandler(); return }
        let identifier = operationID
        Task { @MainActor [weak self, weak session] in
            defer { completionHandler() }
            guard let self, let session else { return }
            do {
                guard let updated = try await session.commandNativeVideo(video, command: "skip", values: ["interval": skipInterval.seconds]),
                      operationID == identifier, self.pictureInPictureController === pictureInPictureController,
                      self.video?.token == video.token, updated.token == video.token else { return }
                self.video = updated
                pictureInPictureController.requiresLinearPlayback = !NativeVideoTimeline(updated).canSeek
                pictureInPictureController.invalidatePlaybackState()
            } catch {
                guard operationID == identifier else { return }
                if continuation.isArmed { poll(); return }
                finish(restore: false)
                show(error.localizedDescription)
            }
        }
    }
}
