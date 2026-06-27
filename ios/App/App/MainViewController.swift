import UIKit
import WebKit
import Capacitor

// App-local Capacitor plugins (NativePlayer) are NOT auto-discovered under
// Capacitor 8 + SPM the way packaged plugins (@capacitor/preferences) are, so
// Capacitor.Plugins.NativePlayer stays undefined in the WebView. Register the
// instance explicitly here; capacitorDidLoad() runs once the bridge is ready.
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativePlayerPlugin())
        bridge?.registerPluginInstance(DlnaCastPlugin())
    }

    // Keep the WebView out of AirPlay entirely. Capacitor's WKWebView defaults to
    // allowsAirPlayForMediaPlayback = true, so a <video> starting playback pops the
    // system AirPlay prompt / grabs a previously-selected route (黑屏只投声音).
    // AirPlay is handled exclusively by the native AVPlayer (NativePlayer plugin),
    // invoked only when the user taps the AirPlay button.
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.allowsAirPlayForMediaPlayback = false
        return super.webView(with: frame, configuration: configuration)
    }
}
