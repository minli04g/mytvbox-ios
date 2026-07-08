import Foundation
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import Capacitor

// Native video playback for the in-app mytvbox UI.
//
// The WebView's <video> only AirPlays audio for HLS; AVPlayer does full video
// AirPlay to Apple TV. The page calls NativePlayer.play({url,title}) with the
// proxied stream URL (referer/UA already baked in, so no extra headers).
//
// For one-tap binge: when an item finishes we emit an "ended" event; the page
// resolves the next episode and calls play() again. If the player is already
// presented we swap the item in place so the AirPlay session continues
// uninterrupted instead of tearing down and re-presenting.
@objc(NativePlayerPlugin)
public class NativePlayerPlugin: CAPPlugin, CAPBridgedPlugin, AVRoutePickerViewDelegate {
    public let identifier = "NativePlayerPlugin"
    public let jsName = "NativePlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "airplayPick", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "lockLandscape", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unlockOrientation", returnType: CAPPluginReturnPromise)
    ]

    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private var pipHostVC: PiPHostViewController?
    private var endObserver: NSObjectProtocol?
    private var interruptObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var remoteCommandsConfigured = false
    private var wasPlayingBeforeInterruption = false
    private var pendingPlay: (url: URL, title: String)?
    private var routePickerView: AVRoutePickerView?
    private var nowPlayingTitle = ""

    @objc func play(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""
        DispatchQueue.main.async { self.presentPlayer(url: url, title: title) }
        call.resolve()
    }

    @objc func pip(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""
        DispatchQueue.main.async {
            self.startPictureInPicture(url: url, title: title) {
                call.resolve()
            } onFailure: { message in
                call.reject(message)
            }
        }
    }

    // One-tap AirPlay: pop the system route picker FIRST (device list), then start
    // playback once the user picks a device — so it's already routed to the chosen
    // TV. Without this, tapping the in-app AirPlay button just opens a local player
    // and the user must tap ITS AirPlay button and pick a device (two steps).
    @objc func airplayPick(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""
        DispatchQueue.main.async {
            guard let host = self.bridge?.viewController?.view else {
                self.presentPlayer(url: url, title: title); call.resolve(); return
            }
            self.pendingPlay = (url, title)
            let picker = AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
            picker.prioritizesVideoDevices = true
            picker.delegate = self
            host.addSubview(picker)
            self.routePickerView = picker
            // Programmatically present the route sheet (tap the picker's inner button).
            var popped = false
            for sub in picker.subviews {
                if let b = sub as? UIButton { b.sendActions(for: .touchUpInside); popped = true; break }
            }
            if !popped {  // subview layout changed across iOS versions → just present
                picker.removeFromSuperview(); self.routePickerView = nil; self.pendingPlay = nil
                self.presentPlayer(url: url, title: title)
            }
            call.resolve()
        }
    }

    public func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        routePickerView.removeFromSuperview()
        self.routePickerView = nil
        guard let p = pendingPlay else { return }
        pendingPlay = nil
        // Let the chosen route activate before playback starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.presentPlayer(url: p.url, title: p.title)
        }
    }

    private func startPictureInPicture(
        url: URL,
        title: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onFailure("Picture in Picture is not supported on this device")
            return
        }
        guard let presenter = self.bridge?.viewController else {
            onFailure("missing presenter")
            return
        }

        playerVC?.dismiss(animated: false)
        playerVC = nil
        removePipHost()

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, policy: .longFormVideo)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
        observeInterruptions()
        configureRemoteCommands()
        nowPlayingTitle = title

        let item = makeItem(url: url, title: title)
        observeEnd(of: item)

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player

        let host = PiPHostViewController()
        host.onStop = { [weak self] in self?.teardown() }
        host.configure(player: player)
        pipHostVC = host

        presenter.addChild(host)
        let bounds = presenter.view.bounds
        host.view.frame = CGRect(x: max(0, bounds.maxX - 2), y: max(0, bounds.maxY - 2), width: 2, height: 2)
        host.view.alpha = 0.02
        host.view.isUserInteractionEnabled = false
        presenter.view.insertSubview(host.view, at: 0)
        host.didMove(toParent: presenter)

        observeTime(of: player)
        updateNowPlaying(player: player, item: item)
        player.play()
        updateNowPlaying(player: player, item: item)

        host.startPictureInPicture(retries: 10) { [weak self] in
            guard let self = self else { return }
            self.updateNowPlaying(player: player, item: item)
            onSuccess()
        } onFailure: { [weak self] message in
            self?.teardown()
            onFailure(message)
        }
    }

    // Set up the audio session and present the AVPlayer (shared by play + airplayPick).
    private func presentPlayer(url: URL, title: String) {
        // .playback keeps audio alive for AirPlay / lock-screen continuation.
        // .longFormVideo route-sharing policy is the key for AirPlay-to-TV: it tells
        // iOS this is long-form VIDEO, so the system prefers a video-capable AirPlay
        // route AND gives the playback its own route — a Xiaomi/smart-TV no longer
        // grabs audio-only, and incidental audio (a call) won't leak onto the route.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, policy: .longFormVideo)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
        observeInterruptions()
        configureRemoteCommands()
        nowPlayingTitle = title

        let item = makeItem(url: url, title: title)
        observeEnd(of: item)

        // Already on screen → swap the item so AirPlay continues seamlessly.
        if let player = self.player, self.playerVC?.presentingViewController != nil {
            player.replaceCurrentItem(with: item)
            observeTime(of: player)
            player.play()
            updateNowPlaying(player: player, item: item)
            return
        }

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true                       // AirPlay
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player

        // Subclass so closing the player tears the audio session down — otherwise
        // the AirPlay route lingers and a later call keeps routing to the TV.
        let vc = PlayerViewController()
        vc.onDismiss = { [weak self] in self?.teardown() }
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            vc.canStartPictureInPictureAutomaticallyFromInline = true
        }
        vc.modalPresentationStyle = .fullScreen
        self.playerVC = vc
        observeTime(of: player)
        updateNowPlaying(player: player, item: item)

        guard let presenter = self.bridge?.viewController else { return }
        presenter.present(vc, animated: true) {
            player.play()
            self.updateNowPlaying(player: player, item: item)
        }
    }

    // An incoming call (or any audio interruption) must pause playback — which,
    // for AirPlay video, pauses the show on the TV too, exactly like every other
    // video app. Resume afterwards only if iOS says we should.
    private func observeInterruptions() {
        if interruptObserver != nil { return }
        interruptObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = (self.player?.rate ?? 0) > 0
                self.player?.pause()
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init) ?? []
                if opts.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player?.play()
                }
            @unknown default: break
            }
        }
    }

    // Release the player and the audio session so the AirPlay route is dropped.
    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let o = timeObserver, let player = timeObserverPlayer { player.removeTimeObserver(o) }
        timeObserver = nil
        timeObserverPlayer = nil
        player = nil
        playerVC = nil
        removePipHost()
        nowPlayingTitle = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = interruptObserver { NotificationCenter.default.removeObserver(o); interruptObserver = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removePipHost() {
        guard let host = pipHostVC else { return }
        pipHostVC = nil
        host.onStop = nil
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

    // Force the app into landscape (overrides the device rotation lock) for the
    // player's fullscreen, and release it again.
    @objc func lockLandscape(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.setOrientation(.landscape); call.resolve() }
    }

    @objc func unlockOrientation(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.setOrientation(.all); call.resolve() }
    }

    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        (UIApplication.shared.delegate as? AppDelegate)?.orientationLock = mask
        if #available(iOS 16.0, *) {
            self.bridge?.viewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        } else {
            let o: UIInterfaceOrientation = mask == .landscape ? .landscapeRight : .portrait
            UIDevice.current.setValue(o.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func makeItem(url: URL, title: String) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        if !title.isEmpty {
            let meta = AVMutableMetadataItem()
            meta.identifier = .commonIdentifierTitle
            meta.value = title as NSString
            meta.extendedLanguageTag = "und"
            item.externalMetadata = [meta]
        }
        return item
    }

    private func configureRemoteCommands() {
        if remoteCommandsConfigured { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            self.updateNowPlaying(player: player, item: player.currentItem)
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            player.pause()
            self.updateNowPlaying(player: player, item: player.currentItem)
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            if player.rate == 0 {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            } else {
                player.pause()
            }
            self.updateNowPlaying(player: player, item: player.currentItem)
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let player = self.player,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600)) { _ in
                self.updateNowPlaying(player: player, item: player.currentItem)
            }
            return .success
        }

        center.skipForwardCommand.addTarget { [weak self] event in
            self?.skip(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 15) ?? .commandFailed
        }

        center.skipBackwardCommand.addTarget { [weak self] event in
            self?.skip(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)) ?? .commandFailed
        }
    }

    private func skip(by seconds: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let player = player else { return .commandFailed }
        let current = player.currentTime().seconds
        guard current.isFinite else { return .commandFailed }
        let duration = player.currentItem?.duration.seconds ?? 0
        let upper = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
        let target = min(max(current + seconds, 0), upper)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            self?.updateNowPlaying(player: player, item: player.currentItem)
        }
        return .success
    }

    private func observeTime(of player: AVPlayer) {
        if let o = timeObserver, let oldPlayer = timeObserverPlayer {
            oldPlayer.removeTimeObserver(o)
            timeObserver = nil
            timeObserverPlayer = nil
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self = self, let player = player else { return }
            self.updateNowPlaying(player: player, item: player.currentItem)
        }
        timeObserverPlayer = player
    }

    private func updateNowPlaying(player: AVPlayer, item: AVPlayerItem?) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if !nowPlayingTitle.isEmpty { info[MPMediaItemPropertyTitle] = nowPlayingTitle }
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        let duration = item?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Fire "ended" to JS when the current item finishes so the page can queue
    // the next episode. Re-bind per item; drop the previous observer first.
    private func observeEnd(of item: AVPlayerItem) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.notifyListeners("ended", data: [:])
        }
    }
}

// AVPlayerViewController that reports when it leaves the screen (done button,
// swipe-to-dismiss, or programmatic dismiss) so the plugin can release the
// audio session / AirPlay route. Entering Picture-in-Picture also dismisses the
// VC but playback must continue, so teardown is suppressed while in PiP.
private class PlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    var onDismiss: (() -> Void)?
    private var inPiP = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if inPiP { return }   // PiP window keeps playing; don't tear down.
        // Only when actually going away, not when another VC covers us.
        if isBeingDismissed || isMovingFromParent || presentingViewController == nil {
            onDismiss?()
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ c: AVPlayerViewController) { inPiP = true }
    func playerViewControllerDidStopPictureInPicture(_ c: AVPlayerViewController) {
        inPiP = false
        // PiP closed and the full-screen UI isn't on screen → release.
        if presentingViewController == nil && view.window == nil { onDismiss?() }
    }
}

private class PiPHostViewController: UIViewController, AVPictureInPictureControllerDelegate {
    var onStop: (() -> Void)?

    private let playerLayer = AVPlayerLayer()
    private var pipController: AVPictureInPictureController?
    private var startSucceeded = false
    private var startFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    func configure(player: AVPlayer) {
        playerLayer.player = player
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            pipController = nil
            return
        }
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pipController = controller
    }

    func startPictureInPicture(
        retries: Int,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard let controller = pipController else {
            onFailure("Picture in Picture is not available")
            return
        }

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self else { return }
                if self.startSucceeded || controller.isPictureInPictureActive {
                    onSuccess()
                } else if self.startFailed {
                    onFailure("Picture in Picture failed to start")
                } else {
                    onFailure("Picture in Picture did not start")
                }
            }
            return
        }

        if retries <= 0 {
            onFailure("Picture in Picture is not ready")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startPictureInPicture(retries: retries - 1, onSuccess: onSuccess, onFailure: onFailure)
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        startSucceeded = true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startFailed = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }
}
