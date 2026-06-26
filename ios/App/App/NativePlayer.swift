import Foundation
import AVKit
import AVFoundation
import Capacitor

// Native video playback for the in-app mytvbox UI.
//
// The WebView's <video> only AirPlays audio for HLS; AVPlayer does full video
// AirPlay to Apple TV. The page calls NativePlayer.play({url,title,ep}) with the
// proxied stream URL (referer/UA already baked in, so no extra headers).
//
// Auto-advance uses a real AVQueuePlayer: the page pre-resolves the next few
// episodes and enqueue()s them, so AVFoundation advances item->item on its own.
// That keeps the binge going even when the app is backgrounded / screen locked
// (UIBackgroundModes=audio keeps us alive) — the JS "ended->resolve next" chain
// could NOT, because WKWebView's JS is frozen in the background.
//
// We emit "advanced" {ep} whenever the current item changes so the page (when
// foregrounded) can refill the lookahead window, and "ended" when the queue
// drains.
@objc(NativePlayerPlugin)
public class NativePlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativePlayerPlugin"
    public let jsName = "NativePlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enqueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "lockLandscape", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unlockOrientation", returnType: CAPPluginReturnPromise)
    ]

    private var player: AVQueuePlayer?
    private var playerVC: AVPlayerViewController?
    private var itemObs: NSKeyValueObservation?
    // Maps each queued AVPlayerItem to its episode index so we can report which
    // episode is now playing when the queue advances.
    private var itemEp: [ObjectIdentifier: Int] = [:]

    // Start (or restart) the queue with a single episode. Subsequent episodes are
    // appended via enqueue(). If a player is already on screen we swap the queue
    // in place so the AirPlay session continues uninterrupted.
    @objc func play(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("missing or invalid 'url'")
            return
        }
        let title = call.getString("title") ?? ""
        let ep = call.getInt("ep") ?? 0

        DispatchQueue.main.async {
            // .playback keeps audio/playback alive for AirPlay + background binge.
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { /* non-fatal */ }

            let item = self.makeItem(url: url, title: title)
            self.itemEp.removeAll()
            self.itemEp[ObjectIdentifier(item)] = ep

            // Already on screen → reset the queue to this item, keep the player.
            if let player = self.player, self.playerVC?.presentingViewController != nil {
                player.removeAllItems()
                if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
                player.play()
                call.resolve()
                return
            }

            let player = AVQueuePlayer(items: [item])
            player.allowsExternalPlayback = true                       // AirPlay
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            self.player = player
            self.observeCurrentItem(of: player)

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

    // Append one or more pre-resolved episodes to the tail of the queue.
    // items: [{ url, title, ep }]
    @objc func enqueue(_ call: CAPPluginCall) {
        let items = call.getArray("items", JSObject.self) ?? []
        DispatchQueue.main.async {
            guard let player = self.player else { call.resolve(); return }
            for raw in items {
                guard let urlStr = raw["url"] as? String, let url = URL(string: urlStr) else { continue }
                let title = raw["title"] as? String ?? ""
                let ep = raw["ep"] as? Int ?? -1
                let item = self.makeItem(url: url, title: title)
                self.itemEp[ObjectIdentifier(item)] = ep
                if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
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

    // Report queue position to JS: "advanced" {ep} when a new item starts (the
    // queue auto-advanced, or play() began), "ended" when the queue drains. The
    // page uses "advanced" to refill the lookahead window when foregrounded.
    private func observeCurrentItem(of player: AVQueuePlayer) {
        itemObs = player.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            guard let self = self else { return }
            if let item = p.currentItem {
                let ep = self.itemEp[ObjectIdentifier(item)] ?? -1
                self.notifyListeners("advanced", data: ["ep": ep])
            } else {
                self.notifyListeners("ended", data: [:])
            }
        }
    }
}
