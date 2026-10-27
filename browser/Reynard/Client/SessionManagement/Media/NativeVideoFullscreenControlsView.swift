import UIKit

private final class NativeVideoFullscreenButton: UIButton {
    var visualCenterX: CGFloat = 22 { didSet { if oldValue != visualCenterX { setNeedsLayout() } } }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView?.center = CGPoint(x: visualCenterX, y: bounds.midY)
    }
}

// Touches outside the controls continue to the video. A simultaneous observer
// on the fullscreen host reveals the actions without changing Gecko's input.
final class NativeVideoFullscreenControlsView: UIView, UIGestureRecognizerDelegate {
    var isInline = false { didSet { if oldValue != isInline { updateNativeButtonVisibility() } } }
    var showsNativePlayerButton = true { didSet { if oldValue != showsNativePlayerButton { updateNativeButtonVisibility() } } }
    var videoSize: CGSize? { didSet { if oldValue != videoSize { setNeedsLayout() } } }
    var videoFrameProvider: (() -> CGRect?)?
    var scrollContentFrameProvider: (() -> CGRect?)?
    var scrollActivity: ((Bool) -> Void)?
    var onReveal: (() -> Void)?
    var isPresentingControls: Bool { visibility.isVisible && !scrollSuspended && hasUsableLayout }
    private let pictureInPictureAction: () -> Void
    private let nativePlaybackAction: () -> Void
    private let actions = UIView()
    private let actionsBackground = UIView()
    private let pip = NativeVideoFullscreenButton(type: .system)
    private let native = NativeVideoFullscreenButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let images: (pip: UIImage?, native: UIImage?) = {
        let symbols = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        return (UIImage(systemName: "pip.enter", withConfiguration: symbols),
                UIImage(systemName: "play.rectangle", withConfiguration: symbols))
    }()
    private var busy = false
    private var scrollSuspended = false
    private var hasUsableLayout = false
    private var visibility = NativeVideoFullscreenControlsVisibility()
    private var hideWork: DispatchWorkItem?
    private var scheduledHideDeadline: TimeInterval?
    private weak var gestureHost: UIView?
    private var hostTap: UITapGestureRecognizer?
    private var hostPan: UIPanGestureRecognizer?
    private var recognizedContentPan = false
    private var voiceOverObserver: NSObjectProtocol?

    init(pictureInPicture: @escaping () -> Void, nativePlayback: @escaping () -> Void) {
        pictureInPictureAction = pictureInPicture
        nativePlaybackAction = nativePlayback
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityIdentifier = "native-video-fullscreen-controls"
        actionsBackground.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        actionsBackground.layer.cornerRadius = 12
        actionsBackground.isUserInteractionEnabled = false
        addSubview(actions)
        actions.addSubview(actionsBackground)
        for button in [pip, native] {
            button.tintColor = .white
            actions.addSubview(button)
        }
        activity.color = .white
        activity.isUserInteractionEnabled = false
        actions.addSubview(activity)
        pip.accessibilityLabel = NSLocalizedString("Picture in Picture", comment: "")
        native.accessibilityLabel = NSLocalizedString("Play Video in Native Player", comment: "")
        pip.addTarget(self, action: #selector(startPictureInPicture), for: .touchUpInside)
        native.addTarget(self, action: #selector(startNativePlayback), for: .touchUpInside)
        updateImages()
        updateVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        hideWork?.cancel()
        if let hostTap { gestureHost?.removeGestureRecognizer(hostTap) }
        if let hostPan { gestureHost?.removeGestureRecognizer(hostPan) }
        if let voiceOverObserver { NotificationCenter.default.removeObserver(voiceOverObserver) }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateAttachment()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAttachment()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = isInline
            ? NativeVideoFullscreenControlsLayout.inline(bounds: bounds,
                safeFrame: safeAreaLayoutGuide.layoutFrame, videoFrame: videoFrameProvider?())
            : NativeVideoFullscreenControlsLayout.make(
                bounds: bounds, safeFrame: safeAreaLayoutGuide.layoutFrame,
                videoSize: videoSize, videoFrame: videoFrameProvider?(),
                showsNativePlayerButton: showsNativePlayerButton)
        if actions.frame != layout.actionsFrame { actions.frame = layout.actionsFrame }
        hasUsableLayout = !layout.actionsFrame.isEmpty
        let backgroundFrame = layout.actionsVisualFrame.offsetBy(dx: -actions.frame.minX, dy: -actions.frame.minY)
        if actionsBackground.frame != backgroundFrame { actionsBackground.frame = backgroundFrame }
        let visualCenter = actionsBackground.frame.midX
        let pipFrame = CGRect(x: 0, y: isInline ? 0 : 2, width: actions.bounds.width, height: 44)
        let nativeFrame = CGRect(x: 0, y: 50, width: actions.bounds.width, height: 44)
        if pip.frame != pipFrame { pip.frame = pipFrame }
        if native.frame != nativeFrame { native.frame = nativeFrame }
        pip.visualCenterX = visualCenter
        native.visualCenterX = visualCenter
        let activityCenter = CGPoint(x: visualCenter, y: pip.frame.midY)
        if activity.center != activityCenter { activity.center = activityCenter }
        updatePresentation()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !scrollSuspended else { return nil }
        let target = super.hitTest(point, with: event)
        return target === self || target === actions ? nil : target
    }

    func setScrollSuspended(_ suspended: Bool) {
        guard scrollSuspended != suspended else { return }
        scrollSuspended = suspended
        // Scroll geometry becomes stale until the coordinator obtains a fresh
        // descriptor. Suppression never reveals controls or resets their timer.
        updateVisibility()
    }

    func setBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        // Preparation does not reveal the overlay or extend its deadline.
        // Actions remain usable so an explicit tap can replace preparation.
        let value = busy ? NSLocalizedString("Preparing video", comment: "") : nil
        for button in [pip, native] { button.accessibilityValue = value }
        updatePresentation()
        updateImages()
    }

    private func updateImages() {
        pip.setImage(busy ? nil : images.pip, for: .normal)
        native.setImage(images.native, for: .normal)
    }

    private func updateNativeButtonVisibility() {
        native.isHidden = isInline || !showsNativePlayerButton
        setNeedsLayout()
    }

    private func updateAttachment() {
        let host = window == nil ? nil : superview
        guard host !== gestureHost || (host != nil) != visibility.isAttached else { return }
        // Removing a recognizer need not deliver a cancelled action. End our
        // outstanding drag before removal so discovery cannot remain paused.
        if recognizedContentPan {
            recognizedContentPan = false
            scrollActivity?(false)
        }
        if let hostTap { gestureHost?.removeGestureRecognizer(hostTap) }
        if let hostPan { gestureHost?.removeGestureRecognizer(hostPan) }
        if let voiceOverObserver { NotificationCenter.default.removeObserver(voiceOverObserver) }
        hostTap = nil
        hostPan = nil
        recognizedContentPan = false
        voiceOverObserver = nil
        gestureHost = host
        visibility.detach()

        if let host {
            let tap = UITapGestureRecognizer(target: self, action: #selector(revealFromVideoTap))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            host.addGestureRecognizer(tap)
            hostTap = tap
            let pan = UIPanGestureRecognizer(target: self, action: #selector(observeContentPan(_:)))
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            host.addGestureRecognizer(pan)
            hostPan = pan
            visibility.attach(at: ProcessInfo.processInfo.systemUptime,
                              voiceOver: UIAccessibility.isVoiceOverRunning)
            voiceOverObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.voiceOverStatusDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.visibility.setVoiceOver(UIAccessibility.isVoiceOverRunning,
                                                at: ProcessInfo.processInfo.systemUptime)
                    self.updateVisibility()
                }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        visibility.expire(at: ProcessInfo.processInfo.systemUptime)
        updatePresentation()
        let deadline = visibility.hideDeadline
        // Suppressing an overlay during scrolling does not change its hide
        // deadline. Keep the existing task instead of allocating another one.
        guard deadline != scheduledHideDeadline else { return }
        hideWork?.cancel()
        hideWork = nil
        scheduledHideDeadline = deadline
        guard let deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.scheduledHideDeadline == deadline else { return }
            self.hideWork = nil
            self.scheduledHideDeadline = nil
            self.visibility.expire(at: ProcessInfo.processInfo.systemUptime)
            self.updateVisibility()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    private func updatePresentation() {
        let visible = isPresentingControls
        let hidden = !visible
        if actions.isHidden != hidden { actions.isHidden = hidden }
        if accessibilityElementsHidden != hidden { accessibilityElementsHidden = hidden }
        let showsActivity = visible && busy
        if showsActivity && !activity.isAnimating { activity.startAnimating() }
        else if !showsActivity && activity.isAnimating { activity.stopAnimating() }
        let hidesActivity = !showsActivity
        if activity.isHidden != hidesActivity { activity.isHidden = hidesActivity }
    }

    @objc private func revealFromVideoTap() {
        guard !scrollSuspended else { return }
        visibility.reveal(at: ProcessInfo.processInfo.systemUptime)
        updateVisibility()
        onReveal?()
    }

    @objc private func observeContentPan(_ pan: UIPanGestureRecognizer) {
        guard isInline else { return }
        switch pan.state {
        case .began, .changed:
            guard !recognizedContentPan else { return }
            recognizedContentPan = true
            setScrollSuspended(true)
            scrollActivity?(true)
        case .ended, .cancelled, .failed:
            guard recognizedContentPan else { return }
            recognizedContentPan = false
            // Momentum may continue after the touch ends. Only the coordinator
            // can resume after scrolling settles and geometry is refreshed.
            scrollActivity?(false)
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === hostPan {
            guard isInline, let contentFrame = scrollContentFrameProvider?() ?? videoFrameProvider?(),
                  contentFrame.contains(touch.location(in: self)) else { return false }
        } else if isInline {
            guard let videoFrame = videoFrameProvider?(),
                  videoFrame.contains(touch.location(in: self)) else { return false }
        }
        // Native controls handle their own actions; observing those taps could
        // reveal the overlay again immediately after its PiP button hid it.
        var touchedView = touch.view
        while let view = touchedView {
            if view is UIControl || view === self { return false }
            if view === gestureHost { break }
            touchedView = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func startPictureInPicture() {
        visibility.hideAfterAction()
        updateVisibility()
        pictureInPictureAction()
    }

    @objc private func startNativePlayback() {
        visibility.hideAfterAction()
        updateVisibility()
        nativePlaybackAction()
    }
}
