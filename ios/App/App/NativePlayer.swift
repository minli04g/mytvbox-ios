import Foundation
import AVKit
import AVFoundation
import Capacitor

// Native video playback for the in-app mytvbox UI.
//
// The WebView's hls.js can't AirPlay; AVPlayer can. The mytvbox page calls
// NativePlayer.play({url,title}) with the proxied stream URL
// (http://<pc>:8787/api/stream?...). We present an AVPlayerViewController whose
// route picker / allowsExternalPlayback gives AirPlay-to-Apple-TV for free.
// referer/UA are already baked into the proxy URL, so no extra headers needed.
@objc(NativePlayerPlugin)
public class NativePlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativePlayerPlugin"
    public let jsName = "NativePlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise)
    ]

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

            let item = AVPlayerItem(url: url)
            if !title.isEmpty {
                let meta = AVMutableMetadataItem()
                meta.identifier = .commonIdentifierTitle
                meta.value = title as NSString
                meta.extendedLanguageTag = "und"
                item.externalMetadata = [meta]
            }
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true        // AirPlay
            player.usesExternalPlaybackWhileExternalScreenIsActive = true

            let vc = AVPlayerViewController()
            vc.player = player
            vc.allowsPictureInPicturePlayback = true
            vc.modalPresentationStyle = .fullScreen

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
}
