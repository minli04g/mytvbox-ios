import type { CapacitorConfig } from '@capacitor/cli'

const config: CapacitorConfig = {
  appId: 'top.fancytech.mytvbox',
  appName: '聚影',
  // www/ holds the first-run setup page + offline fallback. There is no fixed
  // server.url: the LAN server IP is dynamic, so the WebView starts on the
  // bundled setup page and then navigates to the user-entered LAN address
  // (http://<pc-ip>:8787). The Capacitor bridge stays injected across that
  // navigation, so the loaded mytvbox UI can still call native plugins.
  webDir: 'www',
  server: {
    // Allow plain-HTTP LAN navigation (mytvbox server is http on the LAN).
    cleartext: true,
    // Any host: the LAN IP is not known at build time.
    allowNavigation: ['*']
  }
}

export default config
