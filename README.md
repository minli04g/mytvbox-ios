# mytvbox-ios

[mytvbox](../mytvbox) 的 iOS 瘦客户端(Capacitor 8)。它本身不含任何源站逻辑——只是一个
WebView 壳,连到你局域网内电脑上跑的 mytvbox 服务,外加一个**原生 AVPlayer 插件**让播放支持
**AirPlay(投 Apple TV)**;DLNA(投小米等通用电视)仍由电脑端 `/api/cast` 完成。

## 工作方式
1. 电脑上跑 mytvbox 服务:`npm run gui`(监听 `0.0.0.0:8787`)。
2. App 首屏(`www/index.html`)让你填一次电脑地址(`192.168.x.x` 或带端口),存入原生 Preferences。
3. WebView 导航到 `http://<电脑IP>:8787/` 加载 mytvbox 界面;Capacitor bridge 跨这次导航仍在,
   所以页面里点播放时能调到原生插件。
4. 播放:页面检测到运行在 App 内 → 把代理流 URL(`/api/stream?...`,已封好 referer/UA)交给
   `NativePlayer`(`ios/App/App/NativePlayer.swift`)→ `AVPlayerViewController` 自带 AirPlay 路由按钮。
5. 右下角 `⚙ 服务器` 浮钮可清除地址、回到首屏重填。

> 前端那一处 App 内分支在主仓 `mytvbox/gui/index.html` 的 `attach()` 里,有 `window.Capacitor`
> 守卫,**桌面浏览器零影响**。

## 关键事实
- Capacitor 8 用 **SPM**(无 CocoaPods);需 **Xcode 26 / Node 22**。
- 工程是经典(非同步)文件引用,所以自定义 `NativePlayer.swift` 由 `scripts/prepare-xcode.rb`
  用 `xcodeproj` gem 在 CI 里登记进 App target(每次 `cap sync` 后幂等执行)。
- `bundle id`:`top.fancytech.mytvbox` · `team`:`C9DKTHSYYB`(与 safebrowser 同账号)。
- 权限:`Info.plist` 有 ATS 明文豁免(连 LAN HTTP)+ 本地网络说明 + 后台音频(AirPlay/锁屏续播)。

## 发布(GitHub Actions → TestFlight)
CI 在 `macos-latest` 上用 fastlane `match`(私有 certs repo,SSH)+ App Store Connect API key。

### 1) 配置仓库 Secrets(值与 safebrowser-ios 相同,可直接复用)
`MATCH_SSH_KEY` · `MATCH_GIT_URL` · `MATCH_PASSWORD` · `ASC_KEY_ID` · `ASC_ISSUER_ID` · `ASC_KEY_CONTENT`
> GitHub Secrets 不跨仓共享,需在本仓重新设置(可用 `gh secret set` 逐个填同样的值)。

### 2) 一次性(因为是全新 bundle id,按顺序各跑一次 `workflow_dispatch`)
1. `lane = create_app` — 在开发者门户注册 App ID + 建 App Store Connect 记录。
2. `lane = init_signing` — 复用已有分发证书 + 为本 bundle id 生成 appstore profile,存入 match repo。

### 3) 日常发布
推一个 `v*` tag(如 `git tag v0.1.0 && git push --tags`)→ 触发 `beta` lane → 构建并上传 TestFlight。

## 本地开发(需 macOS)
```
npm install
npx cap sync ios          # 同步 www + 插件,(在 mac 上)重生成正确的 Package.swift
open ios/App/App.xcodeproj # 用 Xcode 26 打开;真机调试需选你的签名
```
> Windows 上可 `npx cap add/sync` 生成文件,但**构建/签名/真机调试必须在 macOS 或 CI 上**。
