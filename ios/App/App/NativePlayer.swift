import Foundation
import AVKit
import AVFoundation
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
public class NativePlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativePlayerPlugin"
    public let jsName = "NativePlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "lockLandscape", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unlockOrientation", returnType: CAPPluginReturnPromise)
    ]

    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private var endObserver: NSObjectProtocol?
    private var interruptObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    @objc func play(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""

        DispatchQueue.main.async {
            // .playback keeps audio alive for AirPlay / lock-screen continuation.
            // .longFormVideo route-sharing policy is the key for AirPlay-to-TV:
            // it tells iOS this is long-form VIDEO, so the system prefers a
            // video-capable AirPlay route AND gives the playback its own route —
            // a Xiaomi/smart-TV no longer grabs audio-only (黑屏只投声音), and
            // incidental audio (an incoming call, system sounds) won't leak onto
            // the TV route. Without it, .playback defaults to .default and routes
            // decoded audio to any AirPlay device, video left on the phone.
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playback, mode: .moviePlayback, policy: .longFormVideo)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { /* non-fatal */ }
            self.observeInterruptions()

            let item = self.makeItem(url: url, title: title)
            self.observeEnd(of: item)

            // Already on screen → swap the item so AirPlay continues seamlessly.
            if let player = self.player, self.playerVC?.presentingViewController != nil {
                player.replaceCurrentItem(with: item)
                player.play()
                call.resolve()
                return
            }

            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true                       // AirPlay
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            self.player = player

            // Subclass so closing the player (done button / swipe) tears the
            // audio session down — otherwise the AirPlay route lingers and a
            // later call keeps routing to the TV.
            let vc = PlayerViewController()
            vc.onDismiss = { [weak self] in self?.teardown() }
            vc.player = player
            vc.allowsPictureInPicturePlayback = true
            vc.modalPresentationStyle = .fullScreen
            self.playerVC = vc

            guard let presenter = self.bridge?.viewController else {
                call.reject("no view controller to present from")
                return
            }
            presenter.present(vc, animated: true) {
                player.play()
            }
            call.resolve()
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
        player = nil
        playerVC = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = interruptObserver { NotificationCenter.default.removeObserver(o); interruptObserver = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
