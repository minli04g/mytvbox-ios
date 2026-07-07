# mytvbox-ios

[mytvbox](../mytvbox) 的 iOS 瘦客户端（Capacitor 8）。客户端本身不包含源站逻辑，只用 WebView 连接局域网内电脑上运行的 mytvbox 服务，并提供原生播放能力：

- `NativePlayer`：使用 AVPlayer 播放，支持 AirPlay 到 Apple TV。
- `DlnaCast`：在手机所在局域网扫描 DLNA/UPnP MediaRenderer，并通过 AVTransport 投屏到小米等通用电视。

## 工作方式

1. 电脑运行 mytvbox 服务：`npm run gui`，监听 `0.0.0.0:8787`。
2. App 首屏（`www/index.html`）填写一次电脑地址，例如 `192.168.x.x` 或 `192.168.x.x:8787`，保存到 Capacitor Preferences。
3. WebView 导航到 `http://<电脑IP>:8787/` 加载 mytvbox 界面；Capacitor bridge 跨导航保留，所以页面内仍可调用原生插件。
4. 播放时页面会优先调用 App 内的原生能力：
   - AirPlay：调用 `NativePlayer`。
   - DLNA：调用 `DlnaCast.discover/cast/stop/state/seek/pause/resume`。
5. 右下角服务器浮动按钮可清除地址并回到首屏重填。

## DLNA 发现策略

`ios/App/App/DlnaCast.swift` 与 Android/Harmony 客户端保持同一组 JS 可调用方法。iOS 端已启用 Apple 的 Multicast Networking entitlement，发现设备时先走 SSDP M-SEARCH，再回退到 TCP 端口扫描：

- 支持手动 `location` 或 `host`/`port` 优先探测。
- SSDP 搜索 `MediaRenderer`、`AVTransport` 和 `ssdp:all`，读取响应里的 `LOCATION`。
- 自动读取手机 LAN IPv4 的 `/24` 网段。
- 优先扫描常见主端口：`49152, 39620, 49153, 49154, 8200, 7676, 9197`。
- 默认继续扫描次端口：`2869, 1400, 5000, 8060, 1901`；调用时可传 `fullScan: false` 只扫主端口。

## 关键事实

- Capacitor 8 使用 SPM；需要 Xcode 26 / Node 22。
- 自定义 Swift 源文件必须在 Xcode target 的 Sources 中，包括 `NativePlayer.swift`、`MainViewController.swift`、`DlnaCast.swift`。
- 权限：`Info.plist` 包含 ATS 明文豁免（LAN HTTP）、本地网络说明、后台音频；`App.entitlements` 包含 `com.apple.developer.networking.multicast`。
- Bundle id：`top.fancytech.mytvbox`。

## 发布（GitHub Actions 到 TestFlight）

CI 在 `macos-latest` 上使用 fastlane `match` 和 App Store Connect API key。

仓库 Secrets 与 safebrowser-ios 相同，可复用值：

`MATCH_SSH_KEY`、`MATCH_GIT_URL`、`MATCH_PASSWORD`、`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_CONTENT`

日常发布推送 `v*` tag：

```bash
git tag v0.1.0
git push --tags
```

也可以手动触发：

```bash
gh workflow run ios.yml -R minli04g/mytvbox-ios --ref main -f lane=beta
```

## 本地开发

```bash
npm install
npx cap sync ios
open ios/App/App.xcodeproj
```

Windows 可以执行 npm/Capacitor 同步和文本修改；构建、签名、真机调试需要 macOS 或 CI。
