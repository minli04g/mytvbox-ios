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

    @objc func play(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""

        DispatchQueue.main.async {
            // .playback keeps audio alive for AirPlay / lock-screen continuation.
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { /* non-fatal */ }

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

            let vc = AVPlayerViewController()
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
