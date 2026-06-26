import UIKit
import Capacitor

// App-local Capacitor plugins (NativePlayer) are NOT auto-discovered under
// Capacitor 8 + SPM the way packaged plugins (@capacitor/preferences) are, so
// Capacitor.Plugins.NativePlayer stays undefined in the WebView. Register the
// instance explicitly here; capacitorDidLoad() runs once the bridge is ready.
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativePlayerPlugin())
    }
}
